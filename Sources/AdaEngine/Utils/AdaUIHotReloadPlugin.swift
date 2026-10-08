//
//  AdaUIHotReloadPlugin.swift
//  AdaEngine
//
//  Created by AdaEngine on 08.05.2026.
//

#if !WASM && (os(macOS) || os(Linux) || os(Windows))
    import AdaApp
    import AdaAssets
    import AdaUI
    import AdaUtils
    import Foundation
    import Logging

    #if canImport(Darwin)
        import Darwin.C
        import MachO
    #elseif canImport(Glibc)
        import Glibc
    #endif

    /// Plugin that reloads AdaUI hot reload boundaries after source changes.
    ///
    /// The preferred ``ReloadStrategy/automatic`` mode recompiles a changed Swift file, loads a small dynamic
    /// library, interposes matching Swift symbols when the debug binary supports `-interposable`, and redraws
    /// ``View/hotReloading(fileID:function:line:column:)`` boundaries.
    ///
    /// The legacy product-build mode still supports dynamic libraries that export a C symbol with this shape:
    /// ```swift
    /// @_cdecl("ada_ui_hot_reload_make_view")
    /// public func adaUIHotReloadMakeView(_ id: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    ///     switch String(cString: id) {
    ///     case "mobius.deck":
    ///         return AdaUIHotReloadPlugin.retainedOpaqueView(
    ///             UIContainerView(rootView: MobiusRootOverlay(startSlideID: .intro))
    ///         )
    ///     default:
    ///         return nil
    ///     }
    /// }
    /// ```
    ///
    /// The returned pointer must be retained with ``retainedOpaqueView(_:)``. The plugin consumes that retain.
    public struct AdaUIHotReloadPlugin: Plugin {
        /// Selects how source saves are converted into live UI updates.
        public enum ReloadStrategy: Sendable, Equatable {
            /// Try the single-file injection path first, then fall back to the legacy dynamic product build.
            case automatic

            /// Only use the single-file injection path.
            case fastInjectionOnly

            /// Only use the legacy dynamic product build and exported C factory symbol.
            case legacyProductBuild
        }

        public static let defaultEnvironmentKey = "ADAUI_HOT_RELOAD_DYLIB"
        public static let defaultBuildProductEnvironmentKey = "ADAUI_HOT_RELOAD_PRODUCT"
        public static let defaultBuildCommandEnvironmentKey = "ADAUI_HOT_RELOAD_BUILD_COMMAND"
        public static let defaultSymbolName = "ada_ui_hot_reload_make_view"

        private let storage: AdaUIHotReloadPluginStorage

        /// Creates a hot reload plugin.
        ///
        /// - Parameters:
        ///   - filePath: Source file used to discover the surrounding Swift package when `projectDirectory` is omitted.
        ///   - projectDirectory: Project directory to build and watch. Defaults to the current working directory.
        ///   - sourcePaths: Source paths to watch, relative to `projectDirectory` unless absolute.
        ///   - buildCommand: Build command to run from `projectDirectory`. If omitted, `ADAUI_HOT_RELOAD_BUILD_COMMAND`, then `swift build`, is used.
        ///   - buildProduct: Optional SwiftPM product to build. Defaults to `ADAUI_HOT_RELOAD_PRODUCT`.
        ///   - dylibName: Optional dynamic library filename/product hint used when discovering build artifacts.
        ///   - dylibPath: Manual dynamic library override. If omitted, the plugin builds and discovers the dylib.
        ///   - symbolName: Exported C symbol used to create views.
        ///   - watchPaths: Paths to watch. If omitted, `sourcePaths` are watched.
        ///   - reloadIDs: Specific hot-reload ids to reload when the dylib changes. Pass `nil` to reload all hosts.
        ///   - reloadStrategy: Strategy used after a source save.
        ///   - retainedDylibGenerationCount: Number of old dylib generations to keep loaded after hosts are reloaded.
        ///   - latency: File watcher debounce latency.
        public init(
            filePath: StaticString = #filePath,
            projectDirectory: String? = nil,
            sourcePaths: [String] = ["Sources"],
            buildCommand: String? = ProcessInfo.processInfo.environment[Self.defaultBuildCommandEnvironmentKey],
            buildProduct: String? = ProcessInfo.processInfo.environment[Self.defaultBuildProductEnvironmentKey],
            dylibName: String? = nil,
            dylibPath: String? = ProcessInfo.processInfo.environment[Self.defaultEnvironmentKey],
            symbolName: String = Self.defaultSymbolName,
            watchPaths: [String]? = nil,
            reloadIDs: [String]? = nil,
            reloadStrategy: ReloadStrategy = .automatic,
            retainedDylibGenerationCount: Int = 1,
            latency: Double = 0.1
        ) {
            let discoveredProjectDirectory =
                try? AssetsManager
                .resolveProjectDirectories(filePath: filePath)
                .packageDirectory
                .path

            self.storage = AdaUIHotReloadPluginStorage(
                projectDirectory: projectDirectory ?? discoveredProjectDirectory ?? FileManager.default.currentDirectoryPath,
                sourcePaths: sourcePaths,
                buildCommand: buildCommand,
                buildProduct: buildProduct,
                dylibName: dylibName,
                dylibPath: dylibPath,
                symbolName: symbolName,
                watchPaths: watchPaths,
                reloadIDs: reloadIDs,
                reloadStrategy: reloadStrategy,
                retainedDylibGenerationCount: retainedDylibGenerationCount,
                latency: latency
            )
        }

        public func setup(in _: borrowing AppWorlds) {
            storage.setup()
        }

        public func destroy(for _: borrowing AppWorlds) {
            storage.destroy()
        }

        /// Converts a ``UIView`` into the retained opaque pointer expected from the hot-reload dylib symbol.
        public static func retainedOpaqueView(_ view: UIView) -> UnsafeMutableRawPointer {
            unsafe Unmanaged.passRetained(view).toOpaque()
        }
    }

    private final class AdaUIHotReloadPluginStorage: @unchecked Sendable {
        private let projectDirectory: String
        private let sourcePaths: [String]
        private let buildCommand: String?
        private let buildProduct: String?
        private let dylibName: String?
        private let dylibPath: String?
        private let symbolName: String
        private let explicitWatchPaths: [String]?
        private let reloadIDs: [String]?
        private let reloadStrategy: AdaUIHotReloadPlugin.ReloadStrategy
        private let retainedDylibGenerationCount: Int
        private let latency: Double
        private let logger = Logger(label: "org.adaengine.AdaUIHotReloadPlugin")

        private var library: AdaUIHotReloadDynamicLibrary?
        private var injectedLibrary: AdaUIHotReloadInjectedLibrary?
        private var watcher: FileWatcher?
        private var sourceSnapshot: AdaUIHotReloadSourceSnapshot?
        private var isSetup = false
        private var isBuildRunning = false
        private var pendingChangedFiles: Set<URL> = []

        init(
            projectDirectory: String,
            sourcePaths: [String],
            buildCommand: String?,
            buildProduct: String?,
            dylibName: String?,
            dylibPath: String?,
            symbolName: String,
            watchPaths: [String]?,
            reloadIDs: [String]?,
            reloadStrategy: AdaUIHotReloadPlugin.ReloadStrategy,
            retainedDylibGenerationCount: Int,
            latency: Double
        ) {
            self.projectDirectory = projectDirectory
            self.sourcePaths = sourcePaths
            self.buildCommand = buildCommand
            self.buildProduct = buildProduct
            self.dylibName = dylibName
            self.dylibPath = dylibPath
            self.symbolName = symbolName
            self.explicitWatchPaths = watchPaths
            self.reloadIDs = reloadIDs
            self.reloadStrategy = reloadStrategy
            self.retainedDylibGenerationCount = max(0, retainedDylibGenerationCount)
            self.latency = latency
        }

        @MainActor
        func setup() {
            guard !isSetup else {
                logger.debug("Ignoring duplicate AdaUI hot reload setup.")
                return
            }

            isSetup = true
            let projectURL = URL(fileURLWithPath: projectDirectory, isDirectory: true)
                .resolvingSymlinksInPath()
            let library = AdaUIHotReloadDynamicLibrary(
                symbolName: symbolName,
                retainedGenerationCount: retainedDylibGenerationCount,
                logger: logger
            )
            self.library = library
            self.injectedLibrary = AdaUIHotReloadInjectedLibrary(
                retainedGenerationCount: retainedDylibGenerationCount,
                logger: logger
            )

            UIHotReloadRuntime.setFactory { id in
                let view = library.makeView(id: id)
                return view
            }

            sourceSnapshot = AdaUIHotReloadSourceSnapshot.capture(paths: watchPaths(projectURL: projectURL))
            startWatcher(projectURL: projectURL)

            if let dylibPath, !dylibPath.isEmpty {
                let sourceURL = URL(fileURLWithPath: dylibPath).resolvingSymlinksInPath()
                library.reload(from: sourceURL)
                reloadConfiguredHosts()
                library.releaseRetiredGenerations()
            } else if reloadStrategy == .legacyProductBuild {
                scheduleLegacyBuildAndReload(projectURL: projectURL)
            } else {
                logger.info("AdaUI automatic hot reload is ready and will build after the next source save.")
            }
        }

        @MainActor
        func destroy() {
            isSetup = false
            watcher?.stop()
            watcher = nil
            UIHotReloadRuntime.setFactory(nil)
            reloadConfiguredHosts()
            injectedLibrary?.releaseAllGenerations()
            injectedLibrary = nil
            library?.releaseAllGenerations()
            library = nil
        }

        @MainActor
        private func startWatcher(projectURL: URL) {
            let paths = watchPaths(projectURL: projectURL)
            guard !paths.isEmpty else {
                logger.warning("AdaUI hot reload did not start a watcher because no valid watch paths were found.")
                return
            }

            watcher = FileWatcher(paths: paths, latency: latency) { [weak self] changedPaths in
                Task { @MainActor [weak self] in
                    self?.logger.info("✍️ AdaUI hot reload file event: \(Self.uniquePathStrings(changedPaths).joined(separator: ", "))")
                    guard let self else {
                        return
                    }

                    if let dylibPath = self.dylibPath, !dylibPath.isEmpty {
                        guard self.consumeSaveEvent(projectURL: projectURL) != nil else {
                            return
                        }

                        self.library?.reload(from: URL(fileURLWithPath: dylibPath).resolvingSymlinksInPath())
                        self.reloadConfiguredHosts()
                        self.library?.releaseRetiredGenerations()
                    } else {
                        guard let changes = self.consumeSaveEvent(projectURL: projectURL) else {
                            return
                        }

                        self.scheduleReload(projectURL: projectURL, changedFiles: changes.changedFiles)
                    }
                }
            }

            do {
                try watcher?.start()
                logger.info("Started AdaUI hot reload watcher for \(paths.map(\.pathString).joined(separator: ", "))")
            } catch {
                logger.error("❌ Failed to start AdaUI hot reload watcher: \(error)")
                watcher = nil
            }
        }

        private static func uniquePathStrings(_ paths: [AbsolutePath]) -> [String] {
            Array(Set(paths.map(\.pathString))).sorted()
        }

        @MainActor
        private func watchPaths(projectURL: URL) -> [AbsolutePath] {
            let rawPaths = explicitWatchPaths ?? sourcePaths

            return rawPaths.compactMap { path in
                let url = URL(fileURLWithPath: path, relativeTo: projectURL).standardizedFileURL
                do {
                    return try AbsolutePath(validating: url.path)
                } catch {
                    logger.warning("Ignoring invalid AdaUI hot reload watch path \(path): \(error)")
                    return nil
                }
            }
        }

        @MainActor
        private func consumeSaveEvent(projectURL: URL) -> AdaUIHotReloadSourceChanges? {
            let nextSnapshot = AdaUIHotReloadSourceSnapshot.capture(paths: watchPaths(projectURL: projectURL))
            defer {
                sourceSnapshot = nextSnapshot
            }

            guard let sourceSnapshot else {
                return AdaUIHotReloadSourceChanges(changedFiles: nextSnapshot.allFiles())
            }

            let changedFiles = nextSnapshot.changedFiles(comparedTo: sourceSnapshot)
            if changedFiles.isEmpty {
                logger.debug("Ignoring AdaUI hot reload file event because watched file save state did not change.")
                return nil
            }

            return AdaUIHotReloadSourceChanges(changedFiles: changedFiles)
        }

        @MainActor
        private func scheduleReload(projectURL: URL, changedFiles: [URL]) {
            if isBuildRunning {
                pendingChangedFiles.formUnion(changedFiles)
                return
            }

            isBuildRunning = true
            let changedFiles = Array(Set(changedFiles))

            Task {
                let result = await self.reloadResult(projectURL: projectURL, changedFiles: changedFiles)
                await MainActor.run {
                    self.isBuildRunning = false

                    switch result {
                    case let .injected(dylibURL):
                        self.injectedLibrary?.reload(from: dylibURL)
                        self.reloadAllHosts()
                        self.injectedLibrary?.releaseRetiredGenerations()
                    case let .legacy(dylibURL):
                        self.library?.reload(from: dylibURL)
                        self.reloadConfiguredHosts()
                        self.library?.releaseRetiredGenerations()
                    case let .failure(error):
                        self.logger.error("❌ \(error)")
                    }

                    if !self.pendingChangedFiles.isEmpty {
                        let pendingChangedFiles = Array(self.pendingChangedFiles)
                        self.pendingChangedFiles.removeAll()
                        self.scheduleReload(projectURL: projectURL, changedFiles: pendingChangedFiles)
                    }
                }
            }
        }

        @MainActor
        private func scheduleLegacyBuildAndReload(projectURL: URL) {
            if isBuildRunning {
                pendingChangedFiles.insert(projectURL)
                return
            }

            isBuildRunning = true
            Task {
                let result = await self.legacyBuildResult(projectURL: projectURL)
                await MainActor.run {
                    self.isBuildRunning = false

                    switch result {
                    case let .success(dylibURL):
                        self.library?.reload(from: dylibURL)
                        self.reloadConfiguredHosts()
                        self.library?.releaseRetiredGenerations()
                    case let .failure(error):
                        self.logger.error("❌ \(error)")
                    }

                    if !self.pendingChangedFiles.isEmpty {
                        self.pendingChangedFiles.removeAll()
                        self.scheduleLegacyBuildAndReload(projectURL: projectURL)
                    }
                }
            }
        }

        private func reloadResult(projectURL: URL, changedFiles: [URL]) async -> AdaUIHotReloadResult {
            switch reloadStrategy {
            case .automatic:
                let fastResult = await fastInjectionResult(projectURL: projectURL, changedFiles: changedFiles)
                switch fastResult {
                case let .success(dylibURL):
                    return .injected(dylibURL)
                case let .failure(fastError):
                    logger.warning("AdaUI fast hot reload unavailable, falling back to legacy build: \(fastError)")
                    let legacyResult = await legacyBuildResult(projectURL: projectURL)
                    switch legacyResult {
                    case let .success(dylibURL):
                        return .legacy(dylibURL)
                    case let .failure(legacyError):
                        return .failure(legacyError)
                    }
                }
            case .fastInjectionOnly:
                let fastResult = await fastInjectionResult(projectURL: projectURL, changedFiles: changedFiles)
                switch fastResult {
                case let .success(dylibURL):
                    return .injected(dylibURL)
                case let .failure(error):
                    return .failure(error)
                }
            case .legacyProductBuild:
                let legacyResult = await legacyBuildResult(projectURL: projectURL)
                switch legacyResult {
                case let .success(dylibURL):
                    return .legacy(dylibURL)
                case let .failure(error):
                    return .failure(error)
                }
            }
        }

        private func fastInjectionResult(
            projectURL: URL,
            changedFiles: [URL]
        ) async -> Result<URL, AdaUIHotReloadFastInjectionError> {
            let runner = AdaUIHotReloadFastInjectionRunner(
                projectURL: projectURL,
                sourcePaths: sourcePaths,
                changedFiles: changedFiles
            )

            return await runner.build()
        }

        private func legacyBuildResult(projectURL: URL) async -> Result<URL, AdaUIHotReloadBuildError> {
            let runner = AdaUIHotReloadBuildRunner(
                projectURL: projectURL,
                sourcePaths: sourcePaths,
                buildCommand: buildCommand,
                buildProduct: buildProduct,
                dylibName: dylibName ?? buildProduct
            )

            return await runner.build()
        }

        @MainActor
        private func reloadConfiguredHosts() {
            if let reloadIDs {
                for id in reloadIDs {
                    UIHotReloadRuntime.reload(id: id)
                }
            } else {
                UIHotReloadRuntime.reloadAll()
            }
        }

        @MainActor
        private func reloadAllHosts() {
            UIHotReloadRuntime.reloadAll()
        }
    }

    private struct AdaUIHotReloadSourceChanges {
        var changedFiles: [URL]
    }

    private enum AdaUIHotReloadResult {
        case injected(URL)
        case legacy(URL)
        case failure(any Error)
    }

    private struct AdaUIHotReloadSourceSnapshot: Equatable {
        private struct FileState: Equatable {
            var size: Int
            var modificationDate: Date
        }

        private var files: [String: FileState]

        static func capture(paths: [AbsolutePath]) -> Self {
            var files: [String: FileState] = [:]

            for path in paths {
                let url = URL(fileURLWithPath: path.pathString).standardizedFileURL
                collectFiles(at: url, into: &files)
            }

            return Self(files: files)
        }

        func allFiles() -> [URL] {
            files.keys
                .sorted()
                .map(URL.init(fileURLWithPath:))
        }

        func changedFiles(comparedTo previous: Self) -> [URL] {
            Set(files.keys)
                .union(previous.files.keys)
                .filter { files[$0] != previous.files[$0] }
                .sorted()
                .map(URL.init(fileURLWithPath:))
        }

        private static func collectFiles(
            at url: URL,
            into files: inout [String: FileState]
        ) {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
                return
            }

            if values.isDirectory == true {
                collectDirectoryFiles(at: url, into: &files)
            } else if values.isRegularFile == true {
                collectFile(at: url, into: &files)
            }
        }

        private static func collectDirectoryFiles(
            at directoryURL: URL,
            into files: inout [String: FileState]
        ) {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: directoryURL,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            else {
                return
            }

            for case let url as URL in enumerator {
                collectFile(at: url, into: &files)
            }
        }

        private static func collectFile(
            at url: URL,
            into files: inout [String: FileState]
        ) {
            guard
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                values.isRegularFile == true,
                let modificationDate = values.contentModificationDate
            else {
                return
            }

            files[url.standardizedFileURL.path] = FileState(
                size: values.fileSize ?? 0,
                modificationDate: modificationDate
            )
        }
    }

    private struct AdaUIHotReloadFastInjectionRunner: Sendable {
        let projectURL: URL
        let sourcePaths: [String]
        let changedFiles: [URL]

        func build() async -> Result<URL, AdaUIHotReloadFastInjectionError> {
            do {
                let changedFile = try changedSwiftSourceFile()
                let buildDescription = try readSwiftPMBuildDescription()
                guard buildDescription.contains("\"-interposable\"") else {
                    throw AdaUIHotReloadFastInjectionError.interposableMissing
                }

                let command = try swiftModuleBuildCommand(
                    for: changedFile,
                    in: buildDescription
                )
                try run(executable: command.executable, arguments: command.arguments)

                let objectURL = try objectURL(
                    for: changedFile,
                    outputFileMapURL: command.outputFileMapURL
                )
                let dylibURL = try linkInjectedDylib(
                    objectURL: objectURL,
                    command: command
                )

                return .success(dylibURL)
            } catch let error as AdaUIHotReloadFastInjectionError {
                return .failure(error)
            } catch {
                return .failure(.failed("\(error)"))
            }
        }

        private func changedSwiftSourceFile() throws -> URL {
            let swiftFiles =
                changedFiles
                .map(\.standardizedFileURL)
                .filter { $0.pathExtension == "swift" }
                .filter(isWatchedSourceFile(_:))

            guard swiftFiles.count == 1, let changedFile = swiftFiles.first else {
                throw AdaUIHotReloadFastInjectionError.unsupportedChangedFiles(changedFiles.map(\.path))
            }

            return changedFile
        }

        private func isWatchedSourceFile(_ fileURL: URL) -> Bool {
            let filePath = fileURL.standardizedFileURL.path
            return sourcePaths.contains { sourcePath in
                let sourceURL = URL(fileURLWithPath: sourcePath, relativeTo: projectURL)
                    .standardizedFileURL
                return filePath == sourceURL.path || filePath.hasPrefix(sourceURL.path + "/")
            }
        }

        private func readSwiftPMBuildDescription() throws -> String {
            let candidates = [
                projectURL.appendingPathComponent(".build/debug.yaml"),
                projectURL.appendingPathComponent(".build/arm64-apple-macosx/debug.yaml"),
            ]

            for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }

            throw AdaUIHotReloadFastInjectionError.buildDescriptionMissing
        }

        private func swiftModuleBuildCommand(
            for changedFile: URL,
            in buildDescription: String
        ) throws -> SwiftModuleBuildCommand {
            let changedPath = changedFile.standardizedFileURL.path
            let blocks = buildDescription.components(separatedBy: "\n\n")

            for block in blocks where block.contains(changedPath) && block.contains("args: [") {
                guard
                    let args = parseArguments(from: block),
                    let executable = args.first,
                    executable.hasSuffix("/swiftc"),
                    let outputFileMap = value(after: "-output-file-map", in: args)
                else {
                    continue
                }

                let outputFileMapURL = URL(fileURLWithPath: outputFileMap, relativeTo: projectURL)
                    .standardizedFileURL

                guard FileManager.default.fileExists(atPath: outputFileMapURL.path) else {
                    continue
                }

                return SwiftModuleBuildCommand(
                    executable: URL(fileURLWithPath: executable),
                    arguments: Array(args.dropFirst()),
                    outputFileMapURL: outputFileMapURL
                )
            }

            throw AdaUIHotReloadFastInjectionError.compilationCommandMissing(changedPath)
        }

        private func parseArguments(from block: String) -> [String]? {
            guard let argsRange = block.range(of: "args: [") else {
                return nil
            }

            let start = block.index(before: argsRange.upperBound)
            let lineEnd = block[start...].firstIndex(of: "\n") ?? block.endIndex
            let arrayText = String(block[start..<lineEnd])

            guard
                let data = arrayText.data(using: .utf8),
                let value = try? JSONSerialization.jsonObject(with: data),
                let arguments = value as? [String]
            else {
                return nil
            }

            return arguments
        }

        private func objectURL(
            for changedFile: URL,
            outputFileMapURL: URL
        ) throws -> URL {
            let data = try Data(contentsOf: outputFileMapURL)
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else {
                throw AdaUIHotReloadFastInjectionError.outputFileMapInvalid(outputFileMapURL.path)
            }

            let changedPath = changedFile.standardizedFileURL.path
            let entry = value.first { key, _ in
                URL(fileURLWithPath: key, relativeTo: projectURL).standardizedFileURL.path == changedPath
            }?
            .value

            guard let objectPath = entry?["object"] else {
                throw AdaUIHotReloadFastInjectionError.objectFileMissing(changedPath)
            }

            let objectURL = URL(fileURLWithPath: objectPath, relativeTo: projectURL)
                .standardizedFileURL
            guard FileManager.default.fileExists(atPath: objectURL.path) else {
                throw AdaUIHotReloadFastInjectionError.objectFileMissing(objectURL.path)
            }

            return objectURL
        }

        private func linkInjectedDylib(
            objectURL: URL,
            command: SwiftModuleBuildCommand
        ) throws -> URL {
            let outputDirectory =
                projectURL
                .appendingPathComponent(".build/ada-ui-hot-reload", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )

            let outputURL =
                outputDirectory
                .appendingPathComponent("\(objectURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString)")
                .appendingPathExtension("dylib")

            let objectPaths = [objectURL.path] + requiredSupportObjectPaths(for: objectURL)
            var arguments =
                [
                    "swiftc",
                    "-emit-library",
                ] + objectPaths + [
                    "-o",
                    outputURL.path,
                    "-Xlinker",
                    "-undefined",
                    "-Xlinker",
                    "dynamic_lookup",
                    "-Xlinker",
                    "-install_name",
                    "-Xlinker",
                    "@rpath/\(outputURL.lastPathComponent)",
                ]
            arguments.append(contentsOf: command.linkerContextArguments())

            try run(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: arguments
            )

            return outputURL
        }

        private func requiredSupportObjectPaths(for objectURL: URL) -> [String] {
            let objectDirectory = objectURL.deletingLastPathComponent()
            let supportObjectNames = [
                "resource_bundle_accessor.swift.o"
            ]

            return
                supportObjectNames
                .map { objectDirectory.appendingPathComponent($0).path }
                .filter { $0 != objectURL.path }
                .filter { FileManager.default.fileExists(atPath: $0) }
        }

        private func run(executable: URL, arguments: [String]) throws {
            let process = Process()
            process.currentDirectoryURL = projectURL
            process.executableURL = executable
            process.arguments = arguments

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(bytes: outputData, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw AdaUIHotReloadFastInjectionError.commandFailed(
                    command: Self.shellCommand([executable.path] + arguments),
                    exitCode: process.terminationStatus,
                    output: output
                )
            }
        }

        private func value(after option: String, in arguments: [String]) -> String? {
            guard let index = arguments.firstIndex(of: option) else {
                return nil
            }

            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else {
                return nil
            }

            return arguments[valueIndex]
        }

        private static func shellEscaped(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        private static func shellCommand(_ arguments: [String]) -> String {
            arguments.map(shellEscaped(_:)).joined(separator: " ")
        }
    }

    private struct SwiftModuleBuildCommand {
        let executable: URL
        let arguments: [String]
        let outputFileMapURL: URL

        func linkerContextArguments() -> [String] {
            var result: [String] = []
            var index = arguments.startIndex

            while index < arguments.endIndex {
                let argument = arguments[index]
                if Self.linkerContextOptions.contains(argument) {
                    let valueIndex = arguments.index(after: index)
                    if valueIndex < arguments.endIndex {
                        result.append(argument)
                        result.append(arguments[valueIndex])
                        index = arguments.index(after: valueIndex)
                        continue
                    }
                } else if argument == "-g" {
                    result.append(argument)
                }

                index = arguments.index(after: index)
            }

            return result
        }

        private static let linkerContextOptions: Set<String> = [
            "-target",
            "-sdk",
            "-F",
            "-I",
            "-L",
        ]
    }

    private struct AdaUIHotReloadBuildRunner: Sendable {
        let projectURL: URL
        let sourcePaths: [String]
        let buildCommand: String?
        let buildProduct: String?
        let dylibName: String?

        func build() async -> Result<URL, AdaUIHotReloadBuildError> {
            do {
                let command = resolvedBuildCommand()
                let output = try run(command: command)
                guard let dylibURL = discoverDylib(in: output) else {
                    return .failure(.dynamicLibraryNotFound(command: command, output: output))
                }

                return .success(try relinkHotReloadDylibIfPossible(dylibURL))
            } catch let error as AdaUIHotReloadBuildError {
                return .failure(error)
            } catch {
                return .failure(.buildFailed(command: resolvedBuildCommand(), exitCode: nil, output: "\(error)"))
            }
        }

        private func resolvedBuildCommand() -> String {
            if let buildCommand, !buildCommand.isEmpty {
                return buildCommand
            }

            var command = "swift build --disable-build-manifest-caching"
            if let buildProduct, !buildProduct.isEmpty {
                command += " --product \(Self.shellEscaped(buildProduct))"
            }
            return command
        }

        private func run(command: String) throws -> String {
            let process = Process()
            process.currentDirectoryURL = projectURL

            #if os(Windows)
                process.executableURL = URL(fileURLWithPath: "cmd.exe")
                process.arguments = ["/C", command]
            #else
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-lc", command]
            #endif

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(bytes: outputData, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw AdaUIHotReloadBuildError.buildFailed(
                    command: command,
                    exitCode: process.terminationStatus,
                    output: output
                )
            }

            return output
        }

        private func discoverDylib(in output: String) -> URL? {
            let outputCandidate =
                output
                .components(separatedBy: .whitespacesAndNewlines)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`:;,()[]{}")) }
                .compactMap(candidateURL(from:))
                .filter { !isDebugSymbolsArtifact($0) }
                .filter { !isHotReloadRelinkArtifact($0) }
                .filter(matchesNameHint(_:))
                .max(by: olderThan(_:_:))

            if let outputCandidate {
                return outputCandidate
            }

            let buildDirectory = projectURL.appendingPathComponent(".build", isDirectory: true)
            guard
                let enumerator = FileManager.default.enumerator(
                    at: buildDirectory,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            else {
                return nil
            }

            var candidates: [URL] = []
            for case let url as URL in enumerator {
                guard
                    isDynamicLibrary(url),
                    !isDebugSymbolsArtifact(url),
                    !isHotReloadRelinkArtifact(url),
                    matchesNameHint(url),
                    isRegularFile(url)
                else {
                    continue
                }

                candidates.append(url)
            }

            return candidates.max(by: olderThan(_:_:))
        }

        private func candidateURL(from token: String) -> URL? {
            let url = URL(fileURLWithPath: token, relativeTo: projectURL).standardizedFileURL
            guard
                isDynamicLibrary(url),
                !isDebugSymbolsArtifact(url),
                !isHotReloadRelinkArtifact(url),
                FileManager.default.fileExists(atPath: url.path)
            else {
                return nil
            }

            return url
        }

        private func isDynamicLibrary(_ url: URL) -> Bool {
            switch url.pathExtension.lowercased() {
            case "dylib",
                "so",
                "dll":
                return true
            default:
                return false
            }
        }

        private func matchesNameHint(_ url: URL) -> Bool {
            guard let dylibName, !dylibName.isEmpty else {
                return true
            }

            let filename = url.deletingPathExtension().lastPathComponent.lowercased()
            let hint = dylibName.lowercased()
            return filename == hint || filename == "lib\(hint)" || filename.contains(hint)
        }

        private func isRegularFile(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }

        private func isDebugSymbolsArtifact(_ url: URL) -> Bool {
            url.pathComponents.contains { $0.hasSuffix(".dSYM") }
        }

        private func isHotReloadRelinkArtifact(_ url: URL) -> Bool {
            url.deletingPathExtension().lastPathComponent.hasSuffix(".hot-reload")
        }

        private func olderThan(_ lhs: URL, _ rhs: URL) -> Bool {
            modificationDate(lhs) < modificationDate(rhs)
        }

        private func modificationDate(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }

        private func relinkHotReloadDylibIfPossible(_ dylibURL: URL) throws -> URL {
            #if canImport(Darwin)
                let moduleName = moduleName(fromDylib: dylibURL)
                let buildDirectory = dylibURL.deletingLastPathComponent()
                let linkFileListURL =
                    buildDirectory
                    .appendingPathComponent("\(moduleName).product", isDirectory: true)
                    .appendingPathComponent("Objects.LinkFileList")

                guard FileManager.default.fileExists(atPath: linkFileListURL.path) else {
                    return dylibURL
                }

                let linkFileList = try String(contentsOf: linkFileListURL, encoding: .utf8)
                let objectPaths = targetObjectPaths(
                    in: linkFileList,
                    productModuleName: moduleName
                )

                guard !objectPaths.isEmpty else {
                    return dylibURL
                }

                let outputURL = buildDirectory.appendingPathComponent("lib\(moduleName).hot-reload.dylib")
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    try FileManager.default.removeItem(at: outputURL)
                }

                let arguments =
                    [
                        "swiftc",
                        "-emit-library",
                    ] + objectPaths + [
                        "-o",
                        outputURL.path,
                        "-Xlinker",
                        "-undefined",
                        "-Xlinker",
                        "dynamic_lookup",
                        "-Xlinker",
                        "-install_name",
                        "-Xlinker",
                        "@rpath/\(outputURL.lastPathComponent)",
                    ]

                try runRelinkCommand(arguments: arguments)
                return outputURL
            #else
                return dylibURL
            #endif
        }

        private func targetObjectPaths(
            in linkFileList: String,
            productModuleName: String
        ) -> [String] {
            let objectPaths =
                linkFileList
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { $0.hasSuffix(".o") }
                .filter { FileManager.default.fileExists(atPath: $0) }

            let productTargetBuildPath = "/\(productModuleName).build/"
            let productTargetObjectPaths = objectPaths.filter { $0.contains(productTargetBuildPath) }
            if !productTargetObjectPaths.isEmpty {
                return productTargetObjectPaths
            }

            let sourceBasenames = hotReloadSourceBasenames()
            guard !sourceBasenames.isEmpty else {
                return []
            }

            let selectedBuildDirectories = Set(
                objectPaths.compactMap { objectPath -> String? in
                    guard
                        let sourceBasename = sourceBasename(fromObjectPath: objectPath),
                        sourceBasenames.contains(sourceBasename)
                    else {
                        return nil
                    }

                    return URL(fileURLWithPath: objectPath)
                        .deletingLastPathComponent()
                        .path
                }
            )

            guard !selectedBuildDirectories.isEmpty else {
                return []
            }

            return objectPaths.filter { objectPath in
                selectedBuildDirectories.contains(
                    URL(fileURLWithPath: objectPath)
                        .deletingLastPathComponent()
                        .path
                )
            }
        }

        private func hotReloadSourceBasenames() -> Set<String> {
            var basenames: Set<String> = []

            for path in sourcePaths {
                let sourceURL = URL(fileURLWithPath: path, relativeTo: projectURL).standardizedFileURL
                collectSourceBasenames(at: sourceURL, into: &basenames)
            }

            return basenames
        }

        private func collectSourceBasenames(
            at sourceURL: URL,
            into basenames: inout Set<String>
        ) {
            guard let sourceValues = try? sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
                return
            }

            if sourceValues.isDirectory != true {
                if sourceValues.isRegularFile == true {
                    basenames.insert(sourceURL.lastPathComponent)
                }
                return
            }

            guard
                let enumerator = FileManager.default.enumerator(
                    at: sourceURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            else {
                return
            }

            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }

                basenames.insert(url.lastPathComponent)
            }
        }

        private func sourceBasename(fromObjectPath objectPath: String) -> String? {
            let objectBasename = URL(fileURLWithPath: objectPath).lastPathComponent
            guard objectBasename.hasSuffix(".o") else {
                return nil
            }

            return String(objectBasename.dropLast(2))
        }

        private func moduleName(fromDylib dylibURL: URL) -> String {
            let name = dylibURL.deletingPathExtension().lastPathComponent
            if name.hasPrefix("lib") {
                return String(name.dropFirst(3))
            }

            return name
        }

        private func runRelinkCommand(arguments: [String]) throws {
            let process = Process()
            process.currentDirectoryURL = projectURL
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = arguments

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(bytes: outputData, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw AdaUIHotReloadBuildError.buildFailed(
                    command: Self.shellCommand(["xcrun"] + arguments),
                    exitCode: process.terminationStatus,
                    output: output
                )
            }
        }

        private static func shellEscaped(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        private static func shellCommand(_ arguments: [String]) -> String {
            arguments.map(shellEscaped(_:)).joined(separator: " ")
        }
    }

    @safe
    @MainActor
    private final class AdaUIHotReloadInjectedLibrary {
        @safe
        private struct LoadedGeneration: @unchecked Sendable {
            let handle: UnsafeMutableRawPointer
            let copiedURL: URL
        }

        @unsafe private struct InterposeTuple {
            let replacement: UnsafeRawPointer
            let replacee: UnsafeRawPointer
        }

        private typealias DyldDynamicInterposeFunction =
            @convention(c) (
                UnsafeRawPointer,
                UnsafeRawPointer,
                Int
            ) -> Void

        private let retainedGenerationCount: Int
        private let logger: Logger
        private let copiedLibrariesDirectory: URL

        private var sourceURL: URL?
        private var generation = 0
        private var activeGeneration: LoadedGeneration?
        private var retiredGenerations: [LoadedGeneration] = []

        init(
            retainedGenerationCount: Int,
            logger: Logger
        ) {
            self.retainedGenerationCount = retainedGenerationCount
            self.logger = logger
            self.copiedLibrariesDirectory = FileManager.default
                .temporaryDirectory
                .appendingPathComponent("AdaUIHotReloadInjected", isDirectory: true)
        }

        deinit {
            let logger = logger
            for generation in retiredGenerations {
                Self.close(generation: generation, logger: logger)
            }
        }

        func reload(from sourceURL: URL) {
            self.sourceURL = sourceURL

            do {
                let loaded = try loadAndInterpose(from: sourceURL)
                if let activeGeneration {
                    retiredGenerations.append(activeGeneration)
                }

                activeGeneration = loaded
                logger.info("✅ Loaded AdaUI injected hot reload dylib \(sourceURL.path)")
            } catch {
                logger.error("❌ Failed to inject AdaUI hot reload dylib \(sourceURL.path): \(error)")
            }
        }

        func releaseRetiredGenerations() {
            closeRetiredGenerations(keeping: retainedGenerationCount)
        }

        func releaseAllGenerations() {
            closeRetiredGenerations(keeping: 0)

            if let activeGeneration {
                Self.close(generation: activeGeneration, logger: logger)
                self.activeGeneration = nil
            }
        }

        private func loadAndInterpose(from sourceURL: URL) throws -> LoadedGeneration {
            #if canImport(Darwin)
                let copiedURL = try copySourceDylib(sourceURL)
                guard let handle = unsafe dlopen(copiedURL.path, RTLD_NOW | RTLD_LOCAL) else {
                    throw AdaUIHotReloadPluginError.dynamicLibraryOpenFailed(Self.lastDynamicLibraryError())
                }

                do {
                    let tuples = try interposeTuples(for: copiedURL, handle: handle)
                    try applyInterposeTuples(tuples)
                    return LoadedGeneration(handle: handle, copiedURL: copiedURL)
                } catch {
                    unsafe Self.close(
                        generation: LoadedGeneration(handle: handle, copiedURL: copiedURL),
                        logger: logger
                    )
                    throw error
                }
            #else
                throw AdaUIHotReloadPluginError.unsupportedPlatform
            #endif
        }

        private func interposeTuples(
            for dylibURL: URL,
            handle: UnsafeMutableRawPointer
        ) throws -> [InterposeTuple] {
            #if canImport(Darwin)
                let symbols = try exportedSwiftSymbols(in: dylibURL)
                let defaultHandle = Self.defaultDynamicLookupHandle()
                var tuples: [InterposeTuple] = []
                var missingReplaceeCount = 0
                var identicalAddressCount = 0
                var missingReplacementCount = 0

                for symbol in symbols {
                    guard let replacement = unsafe dlsym(handle, symbol) else {
                        missingReplacementCount += 1
                        continue
                    }
                    guard let replacee = unsafe dlsym(defaultHandle, symbol) else {
                        missingReplaceeCount += 1
                        continue
                    }
                    guard replacement != replacee else {
                        identicalAddressCount += 1
                        continue
                    }

                    tuples.append(
                        InterposeTuple(
                            replacement: UnsafeRawPointer(replacement),
                            replacee: UnsafeRawPointer(replacee)
                        )
                    )
                }

                guard !tuples.isEmpty else {
                    throw AdaUIHotReloadPluginError.noInterposableSymbols(dylibURL.path)
                }

                return tuples
            #else
                throw AdaUIHotReloadPluginError.unsupportedPlatform
            #endif
        }

        private func exportedSwiftSymbols(in dylibURL: URL) throws -> [String] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["nm", "-gU", dylibURL.path]

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(bytes: outputData, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw AdaUIHotReloadPluginError.symbolListingFailed(output)
            }

            return
                output
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> String? in
                    let parts = line.split(whereSeparator: \.isWhitespace)
                    guard
                        parts.count >= 3,
                        parts[1] == "T" || parts[1] == "t"
                    else {
                        return nil
                    }

                    var symbol = String(parts[2])
                    if symbol.hasPrefix("_") {
                        symbol.removeFirst()
                    }

                    guard symbol.hasPrefix("$s") || symbol.hasPrefix("$S") else {
                        return nil
                    }

                    return symbol
                }
        }

        private func applyInterposeTuples(_ tuples: [InterposeTuple]) throws {
            #if canImport(Darwin)
                guard let dyldDynamicInterpose = Self.dyldDynamicInterpose() else {
                    throw AdaUIHotReloadPluginError.dynamicInterposeUnavailable
                }

                var imageCount = 0
                tuples.withUnsafeBufferPointer { buffer in
                    guard let baseAddress = buffer.baseAddress else {
                        return
                    }

                    for index in 0..<_dyld_image_count() {
                        guard let header = _dyld_get_image_header(index) else {
                            continue
                        }

                        imageCount += 1
                        dyldDynamicInterpose(
                            UnsafeRawPointer(header),
                            UnsafeRawPointer(baseAddress),
                            buffer.count
                        )
                    }
                }

            #else
                throw AdaUIHotReloadPluginError.unsupportedPlatform
            #endif
        }

        private func closeRetiredGenerations(keeping retainedCount: Int) {
            let generationsToCloseCount = retiredGenerations.count - retainedCount
            guard generationsToCloseCount > 0 else {
                return
            }

            let generationsToClose = Array(retiredGenerations.prefix(generationsToCloseCount))
            retiredGenerations.removeFirst(generationsToCloseCount)

            for generation in generationsToClose {
                Self.close(generation: generation, logger: logger)
            }
        }

        private func copySourceDylib(_ sourceURL: URL) throws -> URL {
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw AdaUIHotReloadPluginError.dynamicLibraryMissing(sourceURL.path)
            }

            try FileManager.default.createDirectory(
                at: copiedLibrariesDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )

            generation += 1
            let processID = ProcessInfo.processInfo.processIdentifier
            let sourceName = sourceURL.deletingPathExtension().lastPathComponent
            let pathExtension = sourceURL.pathExtension.isEmpty ? "dylib" : sourceURL.pathExtension
            let copiedURL =
                copiedLibrariesDirectory
                .appendingPathComponent("\(sourceName)-\(processID)-\(generation)")
                .appendingPathExtension(pathExtension)

            if FileManager.default.fileExists(atPath: copiedURL.path) {
                try FileManager.default.removeItem(at: copiedURL)
            }

            try FileManager.default.copyItem(at: sourceURL, to: copiedURL)
            return copiedURL
        }

        nonisolated private static func close(generation: LoadedGeneration, logger: Logger) {
            #if canImport(Darwin) || canImport(Glibc)
                if unsafe dlclose(generation.handle) != 0 {
                    logger.warning("❌ Failed to close AdaUI injected hot reload dylib \(generation.copiedURL.path): \(Self.lastDynamicLibraryError())")
                }
            #endif

            do {
                if FileManager.default.fileExists(atPath: generation.copiedURL.path) {
                    try FileManager.default.removeItem(at: generation.copiedURL)
                }
            } catch {
                logger.warning("❌ Failed to remove AdaUI injected hot reload dylib copy \(generation.copiedURL.path): \(error)")
            }
        }

        nonisolated private static func dyldDynamicInterpose() -> DyldDynamicInterposeFunction? {
            #if canImport(Darwin)
                let defaultHandle = defaultDynamicLookupHandle()
                guard let symbol = unsafe dlsym(defaultHandle, "dyld_dynamic_interpose") else {
                    return nil
                }

                return unsafe unsafeBitCast(symbol, to: DyldDynamicInterposeFunction.self)
            #else
                return nil
            #endif
        }

        nonisolated private static func defaultDynamicLookupHandle() -> UnsafeMutableRawPointer? {
            #if canImport(Darwin)
                UnsafeMutableRawPointer(bitPattern: -2)
            #else
                nil
            #endif
        }

        nonisolated private static func lastDynamicLibraryError() -> String {
            #if canImport(Darwin) || canImport(Glibc)
                guard let error = unsafe dlerror() else {
                    return "Unknown dynamic library loading error."
                }

                return unsafe String(cString: error)
            #else
                return "Dynamic library loading is not available on this platform."
            #endif
        }
    }

    @safe
    @MainActor
    private final class AdaUIHotReloadDynamicLibrary {
        typealias MakeViewFunction = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?

        @safe
        private struct LoadedGeneration: @unchecked Sendable {
            let handle: UnsafeMutableRawPointer
            let copiedURL: URL
        }

        @safe
        private struct LoadedMakeViewFunction {
            let function: MakeViewFunction
            let generation: LoadedGeneration
        }

        private var sourceURL: URL?
        private let symbolName: String
        private let retainedGenerationCount: Int
        private let logger: Logger
        private let copiedLibrariesDirectory: URL

        private var generation = 0
        private var makeViewFunction: MakeViewFunction?
        private var activeGeneration: LoadedGeneration?
        private var retiredGenerations: [LoadedGeneration] = []

        init(
            symbolName: String,
            retainedGenerationCount: Int,
            logger: Logger
        ) {
            self.symbolName = symbolName
            self.retainedGenerationCount = retainedGenerationCount
            self.logger = logger
            self.copiedLibrariesDirectory = FileManager.default
                .temporaryDirectory
                .appendingPathComponent("AdaUIHotReload", isDirectory: true)
        }

        deinit {
            let logger = logger
            for generation in retiredGenerations {
                Self.close(generation: generation, logger: logger)
            }
        }

        func reload(from sourceURL: URL) {
            self.sourceURL = sourceURL
            reload()
        }

        func releaseRetiredGenerations() {
            closeRetiredGenerations(keeping: retainedGenerationCount)
        }

        func releaseAllGenerations() {
            unsafe makeViewFunction = nil
            closeRetiredGenerations(keeping: 0)

            if let activeGeneration {
                Self.close(generation: activeGeneration, logger: logger)
                self.activeGeneration = nil
            }
        }

        private func reload() {
            do {
                let loaded = try loadMakeViewFunction()
                if let activeGeneration {
                    retiredGenerations.append(activeGeneration)
                }

                unsafe makeViewFunction = loaded.function
                activeGeneration = loaded.generation
                logger.info("✅ Loaded AdaUI hot reload dylib \(sourceURL?.path ?? "<missing>")")
            } catch {
                logger.error("❌ Failed to load AdaUI hot reload dylib \(sourceURL?.path ?? "<missing>"): \(error)")
            }
        }

        func makeView(id: String) -> UIView? {
            if unsafe makeViewFunction == nil {
                guard sourceURL != nil else {
                    return nil
                }

                reload()
            }

            guard let makeViewFunction = unsafe makeViewFunction else {
                return nil
            }

            let rawView = unsafe id.withCString { idPointer in
                unsafe makeViewFunction(idPointer)
            }

            guard let rawView = unsafe rawView else {
                return nil
            }

            return unsafe Unmanaged<UIView>.fromOpaque(rawView).takeRetainedValue()
        }

        private func loadMakeViewFunction() throws -> LoadedMakeViewFunction {
            #if canImport(Darwin) || canImport(Glibc)
                let copiedURL = try copySourceDylib()
                guard let handle = unsafe dlopen(copiedURL.path, RTLD_NOW | RTLD_LOCAL) else {
                    throw AdaUIHotReloadPluginError.dynamicLibraryOpenFailed(Self.lastDynamicLibraryError())
                }

                guard let symbol = unsafe dlsym(handle, symbolName) else {
                    unsafe Self.close(
                        generation: LoadedGeneration(handle: handle, copiedURL: copiedURL),
                        logger: logger
                    )
                    throw AdaUIHotReloadPluginError.symbolNotFound(symbolName)
                }

                return unsafe LoadedMakeViewFunction(
                    function: unsafeBitCast(symbol, to: MakeViewFunction.self),
                    generation: LoadedGeneration(
                        handle: handle,
                        copiedURL: copiedURL
                    )
                )
            #else
                throw AdaUIHotReloadPluginError.unsupportedPlatform
            #endif
        }

        private func closeRetiredGenerations(keeping retainedCount: Int) {
            let generationsToCloseCount = retiredGenerations.count - retainedCount
            guard generationsToCloseCount > 0 else {
                return
            }

            let generationsToClose = Array(retiredGenerations.prefix(generationsToCloseCount))
            retiredGenerations.removeFirst(generationsToCloseCount)

            for generation in generationsToClose {
                Self.close(generation: generation, logger: logger)
            }
        }

        nonisolated private static func close(generation: LoadedGeneration, logger: Logger) {
            #if canImport(Darwin) || canImport(Glibc)
                if unsafe dlclose(generation.handle) != 0 {
                    logger.warning("❌ Failed to close AdaUI hot reload dylib \(generation.copiedURL.path): \(Self.lastDynamicLibraryError())")
                }
            #endif

            do {
                if FileManager.default.fileExists(atPath: generation.copiedURL.path) {
                    try FileManager.default.removeItem(at: generation.copiedURL)
                }
            } catch {
                logger.warning("❌ Failed to remove AdaUI hot reload dylib copy \(generation.copiedURL.path): \(error)")
            }
        }

        private func copySourceDylib() throws -> URL {
            guard let sourceURL else {
                throw AdaUIHotReloadPluginError.dynamicLibraryMissing("<not built yet>")
            }

            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw AdaUIHotReloadPluginError.dynamicLibraryMissing(sourceURL.path)
            }

            try FileManager.default.createDirectory(
                at: copiedLibrariesDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )

            generation += 1
            let processID = ProcessInfo.processInfo.processIdentifier
            let sourceName = sourceURL.deletingPathExtension().lastPathComponent
            let pathExtension = sourceURL.pathExtension.isEmpty ? "dylib" : sourceURL.pathExtension
            let copiedURL =
                copiedLibrariesDirectory
                .appendingPathComponent("\(sourceName)-\(processID)-\(generation)")
                .appendingPathExtension(pathExtension)

            if FileManager.default.fileExists(atPath: copiedURL.path) {
                try FileManager.default.removeItem(at: copiedURL)
            }

            try FileManager.default.copyItem(at: sourceURL, to: copiedURL)
            return copiedURL
        }

        nonisolated private static func lastDynamicLibraryError() -> String {
            #if canImport(Darwin) || canImport(Glibc)
                guard let error = unsafe dlerror() else {
                    return "Unknown dynamic library loading error."
                }

                return unsafe String(cString: error)
            #else
                return "Dynamic library loading is not available on this platform."
            #endif
        }
    }

    private enum AdaUIHotReloadPluginError: Error, CustomStringConvertible {
        case dynamicLibraryMissing(String)
        case dynamicLibraryOpenFailed(String)
        case dynamicInterposeUnavailable
        case noInterposableSymbols(String)
        case symbolListingFailed(String)
        case symbolNotFound(String)
        case unsupportedPlatform

        var description: String {
            switch self {
            case let .dynamicLibraryMissing(path):
                return "Dynamic library does not exist at \(path)."
            case let .dynamicLibraryOpenFailed(message):
                return message
            case .dynamicInterposeUnavailable:
                return "dyld_dynamic_interpose is unavailable in this process."
            case let .noInterposableSymbols(path):
                return "No matching Swift symbols from \(path) were available for interposing."
            case let .symbolListingFailed(output):
                return "Failed to list injected dylib symbols.\n\(output)"
            case let .symbolNotFound(symbol):
                return "Symbol \(symbol) was not found."
            case .unsupportedPlatform:
                return "Dynamic library hot reload is not supported on this platform."
            }
        }
    }

    private enum AdaUIHotReloadFastInjectionError: Error, CustomStringConvertible {
        case buildDescriptionMissing
        case compilationCommandMissing(String)
        case commandFailed(command: String, exitCode: Int32, output: String)
        case failed(String)
        case interposableMissing
        case objectFileMissing(String)
        case outputFileMapInvalid(String)
        case unsupportedChangedFiles([String])

        var description: String {
            switch self {
            case .buildDescriptionMissing:
                return "SwiftPM build description .build/debug.yaml was not found. Run one normal Debug build first."
            case let .compilationCommandMissing(path):
                return "No Swift compile command was found for changed file \(path)."
            case let .commandFailed(command, exitCode, output):
                return "AdaUI fast hot reload command failed (\(exitCode)) for `\(command)`.\n\(output)"
            case let .failed(message):
                return message
            case .interposableMissing:
                return "Debug binary was not linked with -Xlinker -interposable."
            case let .objectFileMissing(path):
                return "No object file was found for \(path)."
            case let .outputFileMapInvalid(path):
                return "Swift output file map is invalid at \(path)."
            case let .unsupportedChangedFiles(files):
                return "Fast hot reload requires exactly one changed watched Swift source file. Changed files: \(files.joined(separator: ", "))"
            }
        }
    }

    private enum AdaUIHotReloadBuildError: Error, CustomStringConvertible {
        case buildFailed(command: String, exitCode: Int32?, output: String)
        case dynamicLibraryNotFound(command: String, output: String)

        var description: String {
            switch self {
            case let .buildFailed(command, exitCode, output):
                let status = exitCode.map { "exit code \($0)" } ?? "unknown exit code"
                return "AdaUI hot reload build failed (\(status)) for command `\(command)`.\n\(output)"
            case let .dynamicLibraryNotFound(command, output):
                return """
                    AdaUI hot reload build succeeded but no dynamic library artifact was found.
                    Command: `\(command)`
                    Add a dynamic library product for the hot reload target, set `buildProduct`/`ADAUI_HOT_RELOAD_PRODUCT`, or provide `buildCommand`.
                    \(output)
                    """
            }
        }
    }
#endif
