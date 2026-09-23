//
//  AdaWebExportPlugin.swift
//  AdaEngine
//

import Foundation
import PackagePlugin

@main
struct AdaWebExportPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let options: ExportOptions
        do {
            options = try ExportOptions(arguments: arguments, packageDirectory: context.package.directoryURL)
        } catch ExportError.help {
            FileHandle.standardOutput.write(Data(ExportError.help.description.utf8))
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }
        let sdk = try options.swiftSDK ?? detectWasmSDK()
        // Bundle.module embeds this absolute path. Use the same canonical spelling
        // as the resource manifest (notably /tmp versus /private/tmp on macOS).
        let buildDirectory = (options.scratchDirectory ?? context.package.directoryURL.appending(
            component: ".build-web-\(options.product)",
            directoryHint: .isDirectory
        )).resolvingSymlinksInPath().standardizedFileURL
        let sharedBuild = context.package.directoryURL.appending(component: ".build").resolvingSymlinksInPath().standardizedFileURL
        guard buildDirectory.resolvingSymlinksInPath().standardizedFileURL != sharedBuild else {
            throw ExportError.unsafeScratchDirectory
        }
        try prepareBuildDirectory(buildDirectory, packageDirectory: context.package.directoryURL)
        // Resolve first so platform-compatibility patches run on actual private
        // checkouts, including a cold scratch directory with no Yams checkout.
        try run(
            executable: "/usr/bin/env",
            arguments: ["swift", "package", "resolve", "--scratch-path", buildDirectory.path(), "--disable-sandbox", "--disable-keychain"],
            workingDirectory: context.package.directoryURL
        )
        try prepareDependenciesForWASI(in: buildDirectory)

        Diagnostics.remark("Building \(options.product) for WebAssembly with Swift SDK \(sdk)")
        try run(
            executable: "/usr/bin/env",
            arguments: [
                "swift",
                "build",
                "--scratch-path",
                buildDirectory.path(),
                "--disable-sandbox",
                "--skip-update",
                "--disable-keychain",
                "--disable-experimental-prebuilts",
                "--disable-index-store",
                "-j", "4",
                "--product",
                options.product,
                "--swift-sdk",
                sdk,
                "-c",
                options.configuration.rawValue,
                "-Xcc",
                "-DHAVE_UNISTD_H=1",
                "-Xcc",
                "-include",
                "-Xcc",
                context.package.directoryURL.appending(
                    components: "Plugins", "AdaWebExportPlugin", "Compatibility", "AdaScriptWASI.h"
                ).path()
            ],
            workingDirectory: context.package.directoryURL
        )

        let wasm = try findBuiltWasm(
            product: options.product,
            configuration: options.configuration,
            buildDirectory: buildDirectory
        )

        try exportBundle(
            wasm: wasm,
            options: options,
            package: context.package,
            packageDirectory: context.package.directoryURL,
            shaderTranspiler: try context.tool(named: "AdaShaderTranspilerTool").url
        )

        Diagnostics.remark("Exported AdaEngine web app to \(options.outputDirectory.path())")

        if options.serve {
            try serve(directory: options.outputDirectory)
        }
    }

    private func detectWasmSDK() throws -> String {
        let output = try capture(
            executable: "/usr/bin/env",
            arguments: ["swift", "sdk", "list"],
            workingDirectory: nil
        )

        if let sdk = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .flatMap({ line -> [String] in
                line.split(whereSeparator: \.isWhitespace).map(String.init)
            })
            .first(where: { $0.contains("_wasm") && !$0.contains("embedded") })
        {
            return sdk
        }

        throw ExportError.missingWasmSDK("""
        No Swift WebAssembly SDK was found.

        Install a Swift toolchain and matching WASM SDK, then retry. Swift.org documents the current flow here:
        https://www.swift.org/documentation/articles/wasm-getting-started.html

        You can also pass an explicit SDK id:
        swift package plugin --allow-writing-to-package-directory --allow-network-connections all export-web --product <ProductName> --swift-sdk <sdk-id>
        """)
    }

    private func findBuiltWasm(
        product: String,
        configuration: ExportOptions.Configuration,
        buildDirectory: URL
    ) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(
            at: buildDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ExportError.wasmNotFound(product, buildDirectory.path())
        }

        let candidates = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL else {
                return nil
            }
            guard url.lastPathComponent == "\(product).wasm" else {
                return nil
            }
            guard url.pathComponents.contains(configuration.rawValue) else {
                return nil
            }
            return url
        }

        guard let wasm = candidates.sorted(by: { $0.path.count < $1.path.count }).last else {
            throw ExportError.wasmNotFound(product, buildDirectory.path())
        }

        return wasm
    }

    private func prepareBuildDirectory(_ buildDirectory: URL, packageDirectory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: buildDirectory, withIntermediateDirectories: true)

        let packageBuildDirectory = packageDirectory.appending(component: ".build", directoryHint: .isDirectory)
        // Artifact and workspace-state paths can point into an unrelated host
        // scratch build. Let the isolated WASM build resolve those itself.
        for name in ["checkouts", "repositories"] {
            let source = packageBuildDirectory.appending(component: name)
            let destination = buildDirectory.appending(component: name)
            guard fileManager.fileExists(atPath: source.path()), !fileManager.fileExists(atPath: destination.path()) else {
                continue
            }
            try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
        }
    }

    private func prepareDependenciesForWASI(in buildDirectory: URL) throws {
        let fileManager = FileManager.default
        let checkouts = buildDirectory.appending(component: "checkouts", directoryHint: .isDirectory)
        let source = checkouts.appending(components: "Yams", "Sources", "Yams", "Representer.swift")
        guard fileManager.fileExists(atPath: source.path()) else { return }
        let original = try String(contentsOf: source, encoding: .utf8)
        let expression = "String(format: \"%.*g\", DBL_DECIMAL_DIG, value)"

        // The pinned Yams formatter uses a C macro that Foundation does not export on WASI.
        // Double.significandBitCount is 52; IEEE binary64 round-trips with 17 decimal digits.
        // Work only on a private copy: prepareBuildDirectory may have linked shared checkouts.
        let resolvedCheckouts = checkouts.resolvingSymlinksInPath().standardizedFileURL
        let scratchRoot = buildDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        if !resolvedCheckouts.path.hasPrefix(scratchRoot.hasSuffix("/") ? scratchRoot : scratchRoot + "/") {
            let temporary = buildDirectory.appending(component: "web-checkouts-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fileManager.copyItem(at: resolvedCheckouts, to: temporary)
            // Remove the symlink itself, not its shared destination.
            try fileManager.removeItem(at: checkouts)
            try fileManager.moveItem(at: temporary, to: checkouts)
        }
        let replacement = """
        String(format: "%.*g", Int32(ceil(1 + Double(Double.significandBitCount + 1) * log10(2))), value)
        """
        if original.contains(expression) {
            try original.replacingOccurrences(of: expression, with: replacement).write(to: source, atomically: true, encoding: .utf8)
            Diagnostics.remark("Applied portable floating-point precision to the isolated Yams web-build checkout")
        }
        let vmSource = checkouts.appending(components: "gravity-lang", "binding", "GravitySwift", "GravityVirtualMachine.swift")
        guard fileManager.fileExists(atPath: vmSource.path()) else { return }
        let vmOriginal = try String(contentsOf: vmSource, encoding: .utf8)
        // Corelibs Foundation takes unsigned byte buffers, unlike Darwin's C-imported initializer.
        let vmUpdated = vmOriginal
            .replacingOccurrences(
                of: "OutputStream(toBuffer: buffer, capacity: data.count)",
                with: "OutputStream(toBuffer: UnsafeMutableRawPointer(buffer).assumingMemoryBound(to: UInt8.self), capacity: data.count)"
            )
            .replacingOccurrences(of: "let charPointer = pointer.bindMemory(to: CChar.self)", with: "let charPointer = pointer.bindMemory(to: UInt8.self)")
        if vmUpdated != vmOriginal {
            try vmUpdated.write(to: vmSource, atomically: true, encoding: .utf8)
            Diagnostics.remark("Applied Foundation byte-buffer compatibility to the isolated AdaScript VM checkout")
        }
    }

    private func exportBundle(
        wasm: URL,
        options: ExportOptions,
        package: Package,
        packageDirectory: URL,
        shaderTranspiler: URL
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)

        let wasmOutput = options.outputDirectory.appending(component: "\(options.product).wasm", directoryHint: .notDirectory)
        try replaceItem(at: wasmOutput, with: wasm)

        if options.product == "AdaWebPlayer" {
            try "{\"runtimeAPI\":3,\"profile\":\"universal\"}".write(
                to: options.outputDirectory.appending(component: "ada-web-player.json"),
                atomically: true,
                encoding: .utf8
            )
            try replaceItem(
                at: options.outputDirectory.appending(component: "player-audio.js"),
                with: packageDirectory.appending(components: "Plugins", "AdaWebExportPlugin", "Runtime", "player-audio.js")
            )
            try replaceItem(
                at: options.outputDirectory.appending(component: "player-lobby.js"),
                with: packageDirectory.appending(components: "Plugins", "AdaWebExportPlugin", "Runtime", "player-lobby.js")
            )
        }

        let resourceBundles = try copyResourceBundles(
            near: wasm,
            to: options.outputDirectory,
            packageName: package.displayName,
            requiredTargetNames: requiredTargetNames(forProductNamed: options.product, in: package)
        )
        var resourceManifest = try resourceBundles
            .flatMap { bundle in
                try manifestEntries(forResourceBundle: bundle)
            }
        let generatedShaders = try generateWGSLShaders(
            resourceBundles: resourceBundles,
            outputDirectory: options.outputDirectory,
            packageDirectory: packageDirectory,
            shaderTranspiler: shaderTranspiler,
            requiresAllShaders: options.product == "AdaWebPlayer"
        )
        resourceManifest.append(contentsOf: generatedShaders)
        resourceManifest.sort { $0.path < $1.path }
        try writeResourceManifest(
            resourceManifest,
            to: options.outputDirectory.appending(component: "ada-resource-manifest.json", directoryHint: .notDirectory)
        )

        let assetsSource = packageDirectory.appending(component: "Assets", directoryHint: .isDirectory)
        let assetsDestination = options.outputDirectory.appending(component: "Assets", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: assetsSource.path()) {
            if fileManager.fileExists(atPath: assetsDestination.path()) {
                try fileManager.removeItem(at: assetsDestination)
            }
            try fileManager.copyItem(at: assetsSource, to: assetsDestination)
        }
        let runtime = try javascriptKitRuntime(packageDirectory: packageDirectory)
        try replaceItem(
            at: options.outputDirectory.appending(component: "runtime.mjs", directoryHint: .notDirectory),
            with: runtime
        )
        try writeBridgeJSRuntime(
            packageDirectory: packageDirectory,
            to: options.outputDirectory.appending(component: "bridge-js.js", directoryHint: .notDirectory)
        )
        try copyBrowserWASIShim(packageDirectory: packageDirectory, to: options.outputDirectory)
        try copyLoaderAssets(to: options.outputDirectory)

        try indexHTML(product: options.product).write(
            to: options.outputDirectory.appending(component: "index.html", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )
        try mainJS(product: options.product).write(
            to: options.outputDirectory.appending(component: "main.js", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )
        try packageJSON(product: options.product).write(
            to: options.outputDirectory.appending(component: "package.json", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )
        try manifestJSON(product: options.product).write(
            to: options.outputDirectory.appending(component: "ada-web-manifest.json", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )
    }

    private func copyLoaderAssets(to outputDirectory: URL) throws {
        let fileManager = FileManager.default
        let loaderAssetsDirectory = outputDirectory.appending(component: "loader-assets", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: loaderAssetsDirectory, withIntermediateDirectories: true)

        let logoSourceDirectory = URL(fileURLWithPath: "/Users/vlad-prusakov/Developer/adawebsite/public/images", isDirectory: true)
        for logoName in ["ae_logo.svg", "ae_logo~dark.svg"] {
            let source = logoSourceDirectory.appending(component: logoName, directoryHint: .notDirectory)
            guard fileManager.fileExists(atPath: source.path()) else {
                continue
            }

            try replaceItem(
                at: loaderAssetsDirectory.appending(component: logoName, directoryHint: .notDirectory),
                with: source
            )
        }
    }

    private func copyBrowserWASIShim(packageDirectory: URL, to outputDirectory: URL) throws {
        let fileManager = FileManager.default
        let shimSourceDirectory = packageDirectory.appending(
            components: "Plugins", "AdaWebExportPlugin", "BrowserWASIShim",
            directoryHint: .isDirectory
        )
        let shimDestinationDirectory = outputDirectory.appending(component: "browser-wasi-shim", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: shimDestinationDirectory.path()) {
            try fileManager.removeItem(at: shimDestinationDirectory)
        }
        try fileManager.copyItem(at: shimSourceDirectory, to: shimDestinationDirectory)
    }

    private func replaceItem(at destination: URL, with source: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path()) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func copyResourceBundles(
        near wasm: URL,
        to outputDirectory: URL,
        packageName: String,
        requiredTargetNames: Set<String>
    ) throws -> [ResourceBundleExport] {
        let fileManager = FileManager.default
        let buildProductsDirectory = wasm.deletingLastPathComponent()
        let resourceBundles = try fileManager.contentsOfDirectory(
            at: buildProductsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard url.pathExtension == "resources" else {
                return false
            }
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return resourceValues?.isDirectory == true
                && requiredTargetNames.contains(resourceBundleTargetName(for: url, packageName: packageName))
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        let resourcesDirectory = outputDirectory.appending(component: "resources", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: resourcesDirectory.path()) {
            try fileManager.removeItem(at: resourcesDirectory)
        }
        try fileManager.createDirectory(at: resourcesDirectory, withIntermediateDirectories: true)

        var exportedBundles: [ResourceBundleExport] = []
        for source in resourceBundles {
            let destination = resourcesDirectory.appending(component: source.lastPathComponent, directoryHint: .isDirectory)
            if fileManager.fileExists(atPath: destination.path()) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
            exportedBundles.append(ResourceBundleExport(source: source, destination: destination))
        }

        return exportedBundles
    }

    private func generateWGSLShaders(
        resourceBundles: [ResourceBundleExport],
        outputDirectory: URL,
        packageDirectory: URL,
        shaderTranspiler: URL,
        requiresAllShaders: Bool
    ) throws -> [ResourceManifestEntry] {
        let shaderURLs = try resourceBundles
            .flatMap { bundle in
                try regularFiles(in: bundle.source)
            }
            .filter { $0.pathExtension == "glsl" && containsShaderStagePragma($0) }
            .sorted { $0.path() < $1.path() }
        guard !shaderURLs.isEmpty else {
            Diagnostics.remark("No GLSL shader resources need WGSL generation")
            return []
        }

        if requiresAllShaders,
            let cached = try cachedWGSLShaders(
                resourceBundles: resourceBundles,
                outputDirectory: outputDirectory,
                packageDirectory: packageDirectory
            ) {
            Diagnostics.remark("Reused \(cached.count) verified WGSL shaders for the Web Player")
            return cached
        }

        let tintExecutable = try self.tintExecutable(packageDirectory: packageDirectory)
        let moduleIncludeArguments = shaderModuleIncludeArguments(
            resourceBundles: resourceBundles,
            packageDirectory: packageDirectory
        )

        var entries: [ResourceManifestEntry] = []
        for shaderURL in shaderURLs {
            guard let resourceBundle = resourceBundles.first(where: { shaderURL.isDescendant(of: $0.source) }) else {
                continue
            }
            let shaderOutputDirectory = outputURL(forResourceURL: shaderURL, in: resourceBundle).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: shaderOutputDirectory, withIntermediateDirectories: true)

            var arguments = [
                "--input",
                shaderURL.path(),
                "--output-directory",
                shaderOutputDirectory.path(),
                "--tint",
                tintExecutable.path()
            ]
            arguments.append(contentsOf: moduleIncludeArguments)

            do {
                let generatedOutput = try captureStandardOutput(
                    executable: shaderTranspiler.path(),
                    arguments: arguments,
                    workingDirectory: packageDirectory
                )
                let generatedEntries = generatedOutput
                    .split(whereSeparator: \.isNewline)
                    .map(String.init)
                    .compactMap { outputPath -> ResourceManifestEntry? in
                        let outputURL = URL(fileURLWithPath: outputPath)
                        guard FileManager.default.fileExists(atPath: outputURL.path()) else {
                            return nil
                        }
                        let absoluteBuildURL = shaderURL
                            .deletingLastPathComponent()
                            .appending(component: outputURL.lastPathComponent, directoryHint: .notDirectory)
                        return ResourceManifestEntry(
                            path: absoluteBuildURL.path(),
                            // The WGSL exists in the export, not in the SwiftPM resource bundle.
                            url: browserRelativeURL(forRelativePath: outputURL.relativePath(from: outputDirectory))
                        )
                    }
                entries.append(contentsOf: generatedEntries)
            } catch {
                if requiresAllShaders { throw error }
                Diagnostics.warning("Skipping WGSL generation for \(shaderURL.lastPathComponent): \(error)")
            }
        }

        Diagnostics.remark("Generated \(entries.count) WGSL shader resources with Tint")
        return entries
    }

    private func cachedWGSLShaders(
        resourceBundles: [ResourceBundleExport],
        outputDirectory: URL,
        packageDirectory: URL
    ) throws -> [ResourceManifestEntry]? {
        let cacheRoot = packageDirectory.appending(
            components: "Plugins", "AdaWebExportPlugin", "Runtime", "WGSLCache",
            directoryHint: .isDirectory
        )
        guard
            let manifestData = FileManager.default.contents(atPath: cacheRoot.appending(component: "manifest.json").path()),
            let manifest = try? JSONDecoder().decode(CachedShaderManifest.self, from: manifestData),
            manifest.schemaVersion == 1
        else { return nil }

        var currentSources: [String: URL] = [:]
        for bundle in resourceBundles {
            for source in try regularFiles(in: bundle.source) where source.pathExtension == "glsl" {
                let key = bundle.source.lastPathComponent + "/" + source.relativePath(from: bundle.source)
                currentSources[key] = source
            }
        }
        guard Set(currentSources.keys) == Set(manifest.glslHashes.keys),
            currentSources.allSatisfy({ key, source in
                guard let expected = manifest.glslHashes[key].flatMap({ UInt64($0, radix: 16) }),
                    let bytes = FileManager.default.contents(atPath: source.path())
                else { return false }
                var hash: UInt64 = 14_695_981_039_346_656_037
                for byte in bytes {
                    hash ^= UInt64(byte)
                    hash &*= 1_099_511_628_211
                }
                return hash == expected
            })
        else {
            Diagnostics.remark("Precompiled WGSL cache does not match current GLSL sources; using Tint")
            return nil
        }

        let bundlesByName = Dictionary(uniqueKeysWithValues: resourceBundles.map { ($0.source.lastPathComponent, $0) })
        var entries: [ResourceManifestEntry] = []
        for path in manifest.wgslPaths {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                let bundle = bundlesByName[String(parts[0])]
            else { return nil }
            let relative = parts.dropFirst().joined(separator: "/")
            let cached = cacheRoot.appending(path: path, directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: cached.path()) else { return nil }
            let destination = bundle.destination.appending(path: relative, directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try replaceItem(at: destination, with: cached)
            entries.append(ResourceManifestEntry(
                path: bundle.source.appending(path: relative, directoryHint: .notDirectory).path(),
                url: browserRelativeURL(forRelativePath: destination.relativePath(from: outputDirectory))
            ))
        }
        return entries
    }

    private struct CachedShaderManifest: Decodable {
        let schemaVersion: Int
        let glslHashes: [String: String]
        let wgslPaths: [String]
    }

    private func containsShaderStagePragma(_ url: URL) -> Bool {
        guard let data = FileManager.default.contents(atPath: url.path()),
              let source = String(data: data, encoding: .utf8) else {
            return false
        }

        return source.contains("#pragma stage")
    }

    private func regularFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey])
            if resourceValues.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    private func shaderModuleIncludeArguments(resourceBundles: [ResourceBundleExport], packageDirectory: URL) -> [String] {
        let candidates = resourceBundles.map {
            $0.source.appending(components: "Shaders", "Public", directoryHint: .isDirectory)
        } + [
            packageDirectory.appending(
                components: "Sources", "AdaRender", "Assets", "Shaders", "Public",
                directoryHint: .isDirectory
            )
        ]

        guard let publicShaders = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path()) }) else {
            return []
        }

        return [
            "--module-include",
            "AdaEngine=\(publicShaders.path())"
        ]
    }

    private func tintExecutable(packageDirectory: URL) throws -> URL {
        if let override = ProcessInfo.processInfo.environment["TINT_EXECUTABLE"], !override.isEmpty {
            let executable = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: executable.path()) {
                Diagnostics.remark("Using Tint compiler from TINT_EXECUTABLE: \(executable.path())")
                return executable
            }
        }

        if let executable = builtTintExecutable(packageDirectory: packageDirectory) {
            Diagnostics.remark("Using Tint compiler from WebGPUTintPlugin output: \(executable.path())")
            return executable
        }

        if let executable = findExecutableInPATH(named: .tintBinaryName) {
            Diagnostics.remark("Using Tint compiler from PATH: \(executable.path())")
            return executable
        }

        Diagnostics.remark("Tint compiler was not found locally; building Dawn/Tint before WGSL generation")
        try buildTintCompiler(packageDirectory: packageDirectory)

        if let executable = builtTintExecutable(packageDirectory: packageDirectory) {
            Diagnostics.remark("Using newly built Tint compiler: \(executable.path())")
            return executable
        }

        if let executable = findExecutableInPATH(named: .tintBinaryName) {
            Diagnostics.remark("Using Tint compiler from PATH: \(executable.path())")
            return executable
        }

        let expectedExecutable = packageDirectory.appending(
            components: ".build", "plugins", "WebGPUTintPlugin", "outputs", "bin", .tintBinaryPlatform, .tintBinaryName,
            directoryHint: .notDirectory
        )
        throw ExportError.tintNotFound(expectedExecutable.path())
    }

    private func builtTintExecutable(packageDirectory: URL) -> URL? {
        let executable = packageDirectory.appending(
            components: ".build", "plugins", "WebGPUTintPlugin", "outputs", "bin", .tintBinaryPlatform, .tintBinaryName,
            directoryHint: .notDirectory
        )
        guard FileManager.default.isExecutableFile(atPath: executable.path()) else {
            return nil
        }
        return executable
    }

    private func findExecutableInPATH(named name: String) -> URL? {
        let paths = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        return paths
            .map { URL(fileURLWithPath: $0).appending(component: name, directoryHint: .notDirectory) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path()) }
    }

    private func buildTintCompiler(packageDirectory: URL) throws {
        try run(
            executable: "/usr/bin/env",
            arguments: [
                "swift",
                "package",
                "--disable-sandbox",
                "plugin",
                "--allow-network-connections",
                "all",
                "build-tint"
            ],
            workingDirectory: packageDirectory
        )
    }

    private func manifestEntries(forResourceBundle bundle: ResourceBundleExport) throws -> [ResourceManifestEntry] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: bundle.source,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var entries: [ResourceManifestEntry] = []
        for item in enumerator {
            guard let url = item as? URL else {
                continue
            }
            let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else {
                continue
            }
            entries.append(
                ResourceManifestEntry(
                    path: url.path(),
                    url: browserRelativeURL(forResourceURL: url, in: bundle)
                )
            )
        }
        return entries
    }

    private func writeResourceManifest(_ manifest: [ResourceManifestEntry], to output: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: output, options: [.atomic])
    }

    private func outputURL(forResourceURL url: URL, in bundle: ResourceBundleExport) -> URL {
        let relativePath = url.relativePath(from: bundle.source)
        return relativePath
            .components(separatedBy: "/")
            .filter { !$0.isEmpty }
            .reduce(bundle.destination) { partialResult, component in
                partialResult.appending(component: component, directoryHint: .notDirectory)
            }
    }

    private func browserRelativeURL(forResourceURL url: URL, in bundle: ResourceBundleExport) -> String {
        browserRelativeURL(forRelativePath: "resources/\(bundle.destination.lastPathComponent)/\(url.relativePath(from: bundle.source))")
    }

    private func browserRelativeURL(forRelativePath relativePath: String) -> String {
        let allowedCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))
        return "./" + relativePath
            .components(separatedBy: "/")
            .map { component in
                component.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? component
            }
            .joined(separator: "/")
    }

    private func requiredTargetNames(forProductNamed productName: String, in package: Package) -> Set<String> {
        guard let product = package.products.first(where: { $0.name == productName }) else {
            return [productName]
        }

        var names: Set<String> = []
        var stack = product.targets
        while let target = stack.popLast() {
            guard names.insert(target.name).inserted else {
                continue
            }

            for dependency in target.dependencies {
                switch dependency {
                case .target(let target):
                    stack.append(target)
                case .product(let product):
                    stack.append(contentsOf: product.targets)
                @unknown default:
                    continue
                }
            }
        }

        return names
    }

    private func resourceBundleTargetName(for bundle: URL, packageName: String) -> String {
        let bundleName = bundle.deletingPathExtension().lastPathComponent
        let packagePrefix = "\(packageName)_"
        if bundleName.hasPrefix(packagePrefix) {
            return String(bundleName.dropFirst(packagePrefix.count))
        }

        return bundleName.split(separator: "_").last.map(String.init) ?? bundleName
    }

    private func javascriptKitRuntime(packageDirectory: URL) throws -> URL {
        let candidates = [
            packageDirectory.appending(
                components: ".build", "checkouts", "JavaScriptKit", "Plugins", "PackageToJS", "Templates", "runtime.mjs",
                directoryHint: .notDirectory
            ),
            packageDirectory.appending(
                components: ".build", "checkouts", "javascriptkit", "Plugins", "PackageToJS", "Templates", "runtime.mjs",
                directoryHint: .notDirectory
            )
        ]
        if let runtime = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path()) }) {
            return runtime
        }
        throw ExportError.javascriptKitRuntimeNotFound
    }

    private func writeBridgeJSRuntime(packageDirectory: URL, to output: URL) throws {
        guard let skeleton = bridgeJSSkeleton(packageDirectory: packageDirectory) else {
            try """
            export async function createInstantiator() {
              return {
                addImports: () => {},
                setInstance: () => {},
                createExports: () => ({}),
              };
            }
            """.write(to: output, atomically: true, encoding: .utf8)
            return
        }

        if try cachedBridgeJSRuntime(packageDirectory: packageDirectory, skeleton: skeleton, output: output) {
            Diagnostics.remark("Reused verified BridgeJS runtime for the Web Player")
            return
        }

        let bridgeJSPackage = try bridgeJSPackageDirectory(packageDirectory: packageDirectory)
        let bridgeJSTool = try bridgeJSToolExecutable(
            bridgeJSPackage: bridgeJSPackage,
            packageDirectory: packageDirectory
        )
        try runBridgeJSTool(
            executable: bridgeJSTool,
            skeleton: skeleton,
            output: output,
            workingDirectory: packageDirectory
        )
    }

    private func cachedBridgeJSRuntime(packageDirectory: URL, skeleton: URL, output: URL) throws -> Bool {
        let cacheRoot = packageDirectory.appending(
            components: "Plugins", "AdaWebExportPlugin", "Runtime", "BridgeJSCache",
            directoryHint: .isDirectory
        )
        guard
            let data = FileManager.default.contents(atPath: cacheRoot.appending(component: "manifest.json").path()),
            let manifest = try? JSONDecoder().decode(CachedBridgeJSManifest.self, from: data),
            manifest.schemaVersion == 1,
            let expectedSkeleton = UInt64(manifest.skeletonFNV64, radix: 16),
            let expectedRuntime = UInt64(manifest.runtimeFNV64, radix: 16),
            let skeletonBytes = FileManager.default.contents(atPath: skeleton.path()),
            let runtime = try? javascriptKitRuntime(packageDirectory: packageDirectory),
            let runtimeBytes = FileManager.default.contents(atPath: runtime.path()),
            cachedFNV64(skeletonBytes) == expectedSkeleton,
            cachedFNV64(runtimeBytes) == expectedRuntime
        else { return false }
        let cached = cacheRoot.appending(component: "bridge-js.js", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: cached.path()) else { return false }
        try replaceItem(at: output, with: cached)
        return true
    }

    private func cachedFNV64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private struct CachedBridgeJSManifest: Decodable {
        let schemaVersion: Int
        let skeletonFNV64: String
        let runtimeFNV64: String
    }

    private func bridgeJSSkeleton(packageDirectory: URL) -> URL? {
        let candidates = [
            packageDirectory.appending(
                components: ".build", "checkouts", "swan", "Sources", "WebGPU", "Wasm", "Generated", "JavaScript", "BridgeJS.json",
                directoryHint: .notDirectory
            ),
            packageDirectory.appending(
                components: ".build", "checkouts", "Swan", "Sources", "WebGPU", "Wasm", "Generated", "JavaScript", "BridgeJS.json",
                directoryHint: .notDirectory
            )
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path()) })
    }

    private func bridgeJSPackageDirectory(packageDirectory: URL) throws -> URL {
        let candidates = [
            packageDirectory.appending(
                components: ".build", "checkouts", "JavaScriptKit", "Plugins", "BridgeJS",
                directoryHint: .isDirectory
            ),
            packageDirectory.appending(
                components: ".build", "checkouts", "javascriptkit", "Plugins", "BridgeJS",
                directoryHint: .isDirectory
            )
        ]
        if let bridgeJSPackage = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path()) }) {
            return bridgeJSPackage
        }

        let swanDirectoryCandidates = [
            packageDirectory.appending(components: ".build", "checkouts", "swan", directoryHint: .isDirectory),
            packageDirectory.appending(components: ".build", "checkouts", "Swan", directoryHint: .isDirectory)
        ]
        let swanDirectory = swanDirectoryCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path()) })
        if let swanDirectory {
            let nestedBridgeJS = swanDirectory.appending(
                components: ".build", "checkouts", "JavaScriptKit", "Plugins", "BridgeJS",
                directoryHint: .isDirectory
            )
            if FileManager.default.fileExists(atPath: nestedBridgeJS.path()) {
                return nestedBridgeJS
            }
        }

        throw ExportError.bridgeJSPackageNotFound
    }

    private func bridgeJSToolExecutable(bridgeJSPackage: URL, packageDirectory: URL) throws -> URL {
        if let existing = findBridgeJSToolExecutable(in: bridgeJSPackage) {
            return existing
        }

        try run(
            executable: "/usr/bin/env",
            arguments: [
                "swift",
                "build",
                "--disable-sandbox",
                "--package-path",
                bridgeJSPackage.path(),
                "--product",
                "BridgeJSToolInternal"
            ],
            workingDirectory: packageDirectory
        )

        guard let built = findBridgeJSToolExecutable(in: bridgeJSPackage) else {
            throw ExportError.bridgeJSToolNotFound
        }
        return built
    }

    private func findBridgeJSToolExecutable(in bridgeJSPackage: URL) -> URL? {
        let buildDirectory = bridgeJSPackage.appending(component: ".build", directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: buildDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator where url.lastPathComponent == "BridgeJSToolInternal" {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
            if values?.isRegularFile == true, values?.isExecutable == true {
                return url
            }
        }
        return nil
    }

    private func serve(directory: URL) throws {
        Diagnostics.remark("Serving \(directory.path()) at http://127.0.0.1:8080")
        try run(
            executable: "/usr/bin/env",
            arguments: ["python3", "-m", "http.server", "8080", "--directory", directory.path()],
            workingDirectory: directory
        )
    }

    private func run(executable: String, arguments: [String], workingDirectory: URL?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = ProcessInfo.processInfo.environment.merging([
            "ADAENGINE_WEB_EXPORT": "1",
            "BUILD_WASM": "1"
        ]) { _, new in new }
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ExportError.commandFailed(arguments.joined(separator: " "), process.terminationStatus)
        }
    }

    private func capture(executable: String, arguments: [String], workingDirectory: URL?) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ExportError.commandFailed(arguments.joined(separator: " "), process.terminationStatus)
        }
        return output
    }

    private func captureStandardOutput(executable: String, arguments: [String], workingDirectory: URL?) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.environment = ProcessInfo.processInfo.environment.merging([
            "ADAENGINE_WEB_EXPORT": "1",
            "BUILD_WASM": "1"
        ]) { _, new in new }
        try process.run()
        process.waitUntilExit()

        let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let command = ([executable] + arguments).joined(separator: " ")
            throw ExportError.commandFailed(
                errorOutput.isEmpty ? command : "\(command)\n\(errorOutput)",
                process.terminationStatus
            )
        }
        return output
    }

    private func runBridgeJSTool(executable: URL, skeleton: URL, output: URL, workingDirectory: URL?) throws {
        FileManager.default.createFile(atPath: output.path(), contents: nil)
        let outputHandle = try FileHandle(forWritingTo: output)
        defer {
            try? outputHandle.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["emit-js", skeleton.path()]
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = outputHandle
        process.environment = ProcessInfo.processInfo.environment.merging([
            "ADAENGINE_WEB_EXPORT": "1",
            "BUILD_WASM": "1"
        ]) { _, new in new }
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ExportError.commandFailed("\(executable.path()) emit-js \(skeleton.path())", process.terminationStatus)
        }
    }
}

private struct ExportOptions {
    enum Configuration: String {
        case debug
        case release
    }

    let product: String
    let outputDirectory: URL
    let scratchDirectory: URL?
    let swiftSDK: String?
    let configuration: Configuration
    let serve: Bool

    init(arguments: [String], packageDirectory: URL) throws {
        var product: String?
        var outputDirectory = packageDirectory.appending(components: "dist", "web", directoryHint: .isDirectory)
        var scratchDirectory: URL?
        var swiftSDK: String?
        var configuration = Configuration.release
        var serve = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--target", "--product":
                index += 1
                guard index < arguments.count else {
                    throw ExportError.missingValue(argument)
                }
                product = arguments[index]
            case "--output":
                index += 1
                guard index < arguments.count else {
                    throw ExportError.missingValue(argument)
                }
                outputDirectory = URL(fileURLWithPath: arguments[index], relativeTo: packageDirectory)
                    .standardizedFileURL
            case "--scratch-path":
                index += 1
                guard index < arguments.count else {
                    throw ExportError.missingValue(argument)
                }
                scratchDirectory = URL(fileURLWithPath: arguments[index], relativeTo: packageDirectory)
                    .standardizedFileURL
            case "--swift-sdk":
                index += 1
                guard index < arguments.count else {
                    throw ExportError.missingValue(argument)
                }
                swiftSDK = arguments[index]
            case "--debug":
                configuration = .debug
            case "--release":
                configuration = .release
            case "--serve":
                serve = true
            case "--help", "-h":
                throw ExportError.help
            default:
                throw ExportError.unknownArgument(argument)
            }

            index += 1
        }

        guard let product else {
            throw ExportError.missingTarget
        }

        self.product = product
        self.outputDirectory = outputDirectory
        self.scratchDirectory = scratchDirectory
        self.swiftSDK = swiftSDK
        self.configuration = configuration
        self.serve = serve
    }
}

private struct ResourceManifestEntry: Encodable {
    let path: String
    let url: String
}

private struct ResourceBundleExport {
    let source: URL
    let destination: URL
}

private extension URL {
    func isDescendant(of directory: URL) -> Bool {
        let directoryPath = directory.normalizedPath
        let path = normalizedPath
        return path == directoryPath || path.hasPrefix(directoryPath + "/")
    }

    func relativePath(from directory: URL) -> String {
        let directoryPath = directory.normalizedPath
        let path = normalizedPath
        guard path.hasPrefix(directoryPath + "/") else {
            return lastPathComponent
        }

        return String(path.dropFirst(directoryPath.count + 1))
    }

    var normalizedPath: String {
        var path = resolvingSymlinksInPath().standardizedFileURL.path()
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

private extension String {
    static var tintBinaryPlatform: String {
        #if arch(arm64)
        #if os(macOS)
        return "arm64-macos"
        #elseif os(Linux)
        return "arm64-linux"
        #else
        return ""
        #endif
        #else
        #if os(macOS)
        return "x86_64-macos"
        #elseif os(Linux)
        return "x86_64-linux"
        #elseif os(Windows)
        return "x86_64-win32"
        #else
        return ""
        #endif
        #endif
    }

    static var tintBinaryName: String {
        #if os(Windows)
        "tint.exe"
        #else
        "tint"
        #endif
    }
}

private enum ExportError: LocalizedError, CustomStringConvertible {
    case help
    case missingTarget
    case missingValue(String)
    case missingWasmSDK(String)
    case unknownArgument(String)
    case commandFailed(String, Int32)
    case wasmNotFound(String, String)
    case javascriptKitRuntimeNotFound
    case bridgeJSPackageNotFound
    case bridgeJSToolNotFound
    case tintNotFound(String)
    case unsafeScratchDirectory

    var errorDescription: String? {
        description
    }

    var description: String {
        switch self {
        case .help:
            return """
            Usage:
              swift package plugin --allow-writing-to-package-directory --allow-network-connections all export-web --product <ProductName> [--output dist/web] [--scratch-path .build-web-ProductName] [--swift-sdk <sdk-id>] [--debug|--release] [--serve]
            """
        case .unsafeScratchDirectory:
            return "Web export requires an isolated --scratch-path; the shared .build directory cannot be used."
        case .missingTarget:
            return "Missing required --product <ProductName> argument."
        case .missingValue(let argument):
            return "Missing value for \(argument)."
        case .missingWasmSDK(let message):
            return message
        case .unknownArgument(let argument):
            return "Unknown argument: \(argument)"
        case .commandFailed(let command, let status):
            return "Command failed with exit code \(status): \(command)"
        case .wasmNotFound(let product, let buildDirectory):
            return "Could not find built \(product).wasm under \(buildDirectory)."
        case .javascriptKitRuntimeNotFound:
            return "Could not find JavaScriptKit runtime.mjs under .build/checkouts/JavaScriptKit."
        case .bridgeJSPackageNotFound:
            return "Could not find JavaScriptKit BridgeJS package under .build/checkouts."
        case .bridgeJSToolNotFound:
            return "Could not find built BridgeJSToolInternal executable."
        case .tintNotFound(let path):
            return "Tint binary not found at \(path). Install `tint`, set TINT_EXECUTABLE, or run `swift package plugin --allow-network-connections all build-tint` before exporting web builds."
        }
    }
}

private func indexHTML(product: String) -> String {
    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>\(product)</title>
      <style>
        :root {
          color-scheme: light dark;
          --ada-loader-background: radial-gradient(circle at 50% 35%, #f8fafc 0, #e7ecf5 42%, #cdd6e6 100%);
          --ada-loader-card: rgba(255, 255, 255, 0.74);
          --ada-loader-text: #111827;
          --ada-loader-muted: #5b6473;
          --ada-loader-track: rgba(17, 24, 39, 0.13);
          --ada-loader-progress: linear-gradient(90deg, #1d4ed8, #7c3aed, #06b6d4);
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --ada-loader-background: radial-gradient(circle at 50% 35%, #242635 0, #12131b 48%, #07080d 100%);
            --ada-loader-card: rgba(14, 16, 24, 0.72);
            --ada-loader-text: #f8fafc;
            --ada-loader-muted: #a9b0bf;
            --ada-loader-track: rgba(255, 255, 255, 0.14);
            --ada-loader-progress: linear-gradient(90deg, #60a5fa, #a78bfa, #22d3ee);
          }
        }
        html, body, #ada-canvas-root {
          width: 100%;
          height: 100%;
          margin: 0;
          overflow: hidden;
          background: #101014;
        }
        body {
          font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        }
        canvas {
          width: 100%;
          height: 100%;
          outline: none;
        }
        #ada-canvas-root {
          position: fixed;
          inset: 0;
        }
        #ada-loader {
          position: fixed;
          inset: 0;
          z-index: 2147483647;
          display: grid;
          place-items: center;
          background: var(--ada-loader-background);
          color: var(--ada-loader-text);
          transition: opacity 260ms ease, visibility 260ms ease;
        }
        #ada-loader[data-state="hidden"] {
          opacity: 0;
          visibility: hidden;
          pointer-events: none;
        }
        .ada-loader-card {
          width: min(360px, calc(100vw - 48px));
          padding: 32px 30px 28px;
          border: 1px solid rgba(128, 140, 160, 0.2);
          border-radius: 28px;
          background: var(--ada-loader-card);
          box-shadow: 0 22px 70px rgba(0, 0, 0, 0.22);
          text-align: center;
          -webkit-backdrop-filter: blur(24px);
          backdrop-filter: blur(24px);
        }
        .ada-loader-logo {
          width: 116px;
          height: auto;
          margin-bottom: 22px;
          filter: drop-shadow(0 12px 24px rgba(0, 0, 0, 0.18));
        }
        .ada-loader-title {
          margin: 0;
          font-size: 18px;
          font-weight: 700;
          letter-spacing: 0.02em;
        }
        .ada-loader-status {
          min-height: 20px;
          margin: 8px 0 22px;
          color: var(--ada-loader-muted);
          font-size: 13px;
          line-height: 20px;
        }
        .ada-loader-progress-track {
          position: relative;
          height: 8px;
          overflow: hidden;
          border-radius: 999px;
          background: var(--ada-loader-track);
        }
        .ada-loader-progress-bar {
          width: 8%;
          height: 100%;
          border-radius: inherit;
          background: var(--ada-loader-progress);
          box-shadow: 0 0 22px rgba(96, 165, 250, 0.45);
          transition: width 180ms ease;
        }
        .ada-loader-progress-bar[data-indeterminate="true"] {
          position: absolute;
          width: 42%;
          animation: ada-loader-slide 1.15s ease-in-out infinite;
        }
        .ada-loader-percent {
          margin-top: 12px;
          color: var(--ada-loader-muted);
          font-size: 12px;
          font-variant-numeric: tabular-nums;
        }
        #ada-loader[data-state="error"] .ada-loader-progress-bar {
          width: 100%;
          background: linear-gradient(90deg, #ef4444, #f97316);
          animation: none;
        }
        @keyframes ada-loader-slide {
          0% { transform: translateX(-110%); }
          50% { transform: translateX(45%); }
          100% { transform: translateX(240%); }
        }
        @media (prefers-reduced-motion: reduce) {
          #ada-loader, .ada-loader-progress-bar {
            transition: none;
            animation: none;
          }
        }
      </style>
    </head>
    <body>
      <div id="ada-canvas-root"></div>
      <div id="ada-loader" role="status" aria-live="polite" aria-label="Loading \(product)">
        <div class="ada-loader-card">
          <picture>
            <source srcset="./loader-assets/ae_logo~dark.svg" media="(prefers-color-scheme: dark)">
            <img class="ada-loader-logo" src="./loader-assets/ae_logo.svg" alt="AdaEngine">
          </picture>
          <h1 class="ada-loader-title">\(product)</h1>
          <div id="ada-loader-status" class="ada-loader-status">Preparing WebAssembly…</div>
          <div class="ada-loader-progress-track" aria-hidden="true">
            <div id="ada-loader-progress" class="ada-loader-progress-bar" data-indeterminate="true"></div>
          </div>
          <div id="ada-loader-percent" class="ada-loader-percent">0%</div>
        </div>
      </div>
      <script type="module" src="\(product == "AdaWebPlayer" ? "./player-lobby.js" : "./main.js")"></script>
    </body>
    </html>
    """
}

private func mainJS(product: String) -> String {
    """
    \(product == "AdaWebPlayer" ? "import './player-audio.js';" : "")
    import { WASI, File, OpenFile, ConsoleStdout, PreopenDirectory, Directory } from "./browser-wasi-shim/dist/index.js";
    import { createInstantiator } from "./bridge-js.js";
    import { SwiftRuntime } from "./runtime.mjs";

    const loader = document.getElementById("ada-loader");
    const loaderStatus = document.getElementById("ada-loader-status");
    const loaderProgress = document.getElementById("ada-loader-progress");
    const loaderPercent = document.getElementById("ada-loader-percent");
    let lastProgress = 0;

    function updateLoader(progress, status, options = {}) {
      const nextProgress = Math.max(lastProgress, Math.min(100, Math.round(progress)));
      lastProgress = nextProgress;
      if (loaderStatus && status) loaderStatus.textContent = status;
      if (loaderProgress) {
        loaderProgress.dataset.indeterminate = options.indeterminate ? "true" : "false";
        loaderProgress.style.width = `${Math.max(4, nextProgress)}%`;
      }
      if (loaderPercent) loaderPercent.textContent = `${nextProgress}%`;
    }

    function hideLoader() {
      updateLoader(100, "Launching…");
      requestAnimationFrame(() => {
        loader?.setAttribute("data-state", "hidden");
        setTimeout(() => loader?.remove(), 320);
      });
    }

    function failLoader(error) {
      console.error(error);
      loader?.setAttribute("data-state", "error");
      updateLoader(100, `Unable to start: ${error instanceof Error ? error.message : String(error)}`);
    }

    async function fetchArrayBufferWithProgress(url, start, end, status) {
      const response = await fetch(url);
      if (!response.ok) {
        throw new Error(`Failed to fetch ${url}: ${response.status} ${response.statusText}`);
      }

      const contentLength = Number(response.headers.get("content-length"));
      if (!response.body || !Number.isFinite(contentLength) || contentLength <= 0) {
        updateLoader(start, status, { indeterminate: true });
        const buffer = await response.arrayBuffer();
        updateLoader(end, status);
        return buffer;
      }

      const reader = response.body.getReader();
      const chunks = [];
      let received = 0;
      updateLoader(start, status);
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(value);
        received += value.byteLength;
        updateLoader(start + ((end - start) * received / contentLength), status);
      }

      const bytes = new Uint8Array(received);
      let offset = 0;
      for (const chunk of chunks) {
        bytes.set(chunk, offset);
        offset += chunk.byteLength;
      }
      updateLoader(end, status);
      return bytes.buffer;
    }

    async function run() {
      updateLoader(2, "Loading WebAssembly…", { indeterminate: true });
      const wasmURL = new URL("./\(product).wasm", import.meta.url);
      const wasmBytes = await fetchArrayBufferWithProgress(wasmURL, 5, 48, "Loading WebAssembly…");
      updateLoader(52, "Preparing Swift runtime…");
      const swift = new SwiftRuntime();

      if (!navigator.gpu) {
        throw new Error("WebGPU is not supported in this browser.");
      }
      updateLoader(58, "Requesting WebGPU adapter…");
      const adapter = await navigator.gpu.requestAdapter({ powerPreference: "high-performance" });
      if (!adapter) {
        throw new Error("Failed to acquire WebGPU adapter.");
      }
      const optionalFeatures = ["float32-filterable"];
      const requiredFeatures = optionalFeatures.filter((feature) => adapter.features.has(feature));
      updateLoader(64, "Creating WebGPU device…");
      const device = await adapter.requestDevice({ requiredFeatures });
      globalThis.__adaWebGPUAdapter = adapter;
      globalThis.__adaWebGPUDevice = device;

      async function makeResourcePreopenDirectories() {
        updateLoader(68, "Loading resources…");
        const response = await fetch(new URL("./ada-resource-manifest.json", import.meta.url));
        const manifest = response.ok ? await response.json() : [];
        installResourceFetchResolver(manifest);
        const root = new Map();

        let loadedResources = 0;
        for (const entry of manifest) {
          const parts = entry.path.split("/").filter(Boolean);
          let directory = root;
          for (const part of parts.slice(0, -1)) {
            let child = directory.get(part);
            if (!(child instanceof Map)) {
              child = new Map();
              directory.set(part, child);
            }
            directory = child;
          }

          const resourceResponse = await fetch(new URL(entry.url, import.meta.url));
          if (!resourceResponse.ok) throw new Error(`Missing resource ${entry.url}: HTTP ${resourceResponse.status}`);
          const bytes = new Uint8Array(await resourceResponse.arrayBuffer());
          if (entry.path.startsWith("game/") && entry.path.endsWith(".wgsl")) {
            const shader = device.createShaderModule({label: entry.path, code: new TextDecoder().decode(bytes)});
            const info = await shader.getCompilationInfo();
            const errors = info.messages.filter(message => message.type === "error");
            if (errors.length) throw new Error(errors.map(message => `${entry.path}:${message.lineNum}:${message.linePos}: ${message.message}`).join("\\n"));
          }
          directory.set(parts[parts.length - 1], new File(bytes, { readonly: true }));
          loadedResources += 1;
          updateLoader(68 + (manifest.length > 0 ? (10 * loadedResources / manifest.length) : 10), "Loading resources…");
        }

        // SwiftPM incremental resource accessors can retain macOS's /tmp or /var
        // spelling while enumeration resolves /private/tmp or /private/var.
        // Mount both spellings onto the same files, without fetching bytes twice.
        const privateRoot = root.get("private");
        if (privateRoot instanceof Map) {
          for (const name of ["tmp", "var"]) {
            if (!root.has(name) && privateRoot.has(name)) root.set(name, privateRoot.get(name));
          }
        }

        const materialize = (map) => new Directory(
          [...map.entries()].map(([name, value]) => [name, value instanceof Map ? materialize(value) : value])
        );
        const rootEntries = () => [...root.entries()].map(([name, value]) => [name, value instanceof Map ? materialize(value) : value]);
        return [
          new PreopenDirectory("/", rootEntries()),
          new PreopenDirectory(".", rootEntries()),
        ];
      }

      function installResourceFetchResolver(manifest) {
        const originalFetch = globalThis.fetch?.bind(globalThis);
        if (!originalFetch || globalThis.__adaResourceFetchResolverInstalled) return;

        const resourceURLsByPath = new Map();
        for (const entry of manifest) {
          if (!entry || typeof entry.path !== "string" || typeof entry.url !== "string") continue;
          const resourceURL = new URL(entry.url, import.meta.url).href;
          const relativePath = entry.path.replace(/^\\/+/, "");
          resourceURLsByPath.set(entry.path, resourceURL);
          resourceURLsByPath.set(relativePath, resourceURL);
          resourceURLsByPath.set(`/${relativePath}`, resourceURL);
          resourceURLsByPath.set(`./${relativePath}`, resourceURL);
          const macOSAlias = relativePath.replace(/^private\\/(tmp|var)\\//, "$1/");
          if (macOSAlias !== relativePath) {
            for (const prefix of ["", "/", "./"]) resourceURLsByPath.set(prefix + macOSAlias, resourceURL);
          }
        }

        const resolveResourceURL = (input) => {
          const rawURL = typeof input === "string" || input instanceof URL ? String(input) : input?.url;
          if (!rawURL) return null;
          if (resourceURLsByPath.has(rawURL)) return resourceURLsByPath.get(rawURL);
          const pathname = new URL(rawURL, import.meta.url).pathname.replace(/^\\/+/, "");
          if (resourceURLsByPath.has(pathname)) return resourceURLsByPath.get(pathname);
          for (const [resourcePath, resourceURL] of resourceURLsByPath) {
            if (pathname.endsWith(resourcePath.replace(/^\\/+/, ""))) return resourceURL;
          }
          return null;
        };

        globalThis.fetch = (input, init) => {
          const resourceURL = resolveResourceURL(input);
          if (resourceURL) {
            return originalFetch(resourceURL, init);
          }
          return originalFetch(input, init);
        };
        globalThis.__adaResourceFetchResolverInstalled = true;
      }

      const resourcePreopens = await makeResourcePreopenDirectories();
      updateLoader(82, "Configuring WASI…");
      const wasi = new WASI(["\(product).wasm"], [], [
        new OpenFile(new File([])),
        ConsoleStdout.lineBuffered((line) => console.log(line)),
        ConsoleStdout.lineBuffered((line) => console.warn(line)),
        ...resourcePreopens,
      ], { debug: false });
      const importObject = {
        wasi_snapshot_preview1: wasi.wasiImport,
        javascript_kit: swift.wasmImports,
      };
      updateLoader(86, "Preparing JavaScript bridge…");
      const bridgeJS = await createInstantiator({}, swift);
      bridgeJS.addImports(importObject, {});
      let wasmInstance;
      const i64Stack = [];
      const typedArrayStack = [];
      const typedArrayConstructors = [Int8Array, Uint8Array, Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array];
      importObject.bjs.swift_js_push_i64 ??= (value) => {
        i64Stack.push(value);
      };
      importObject.bjs.swift_js_pop_i64 ??= () => i64Stack.pop();
      importObject.bjs.swift_js_push_typed_array ??= (kind, pointer, count) => {
        const constructor = typedArrayConstructors[kind];
        const byteLength = count * constructor.BYTES_PER_ELEMENT;
        const copy = wasmInstance.exports.memory.buffer.slice(pointer, pointer + byteLength);
        typedArrayStack.push(Array.from(new constructor(copy)));
      };

      updateLoader(90, "Instantiating WebAssembly…", { indeterminate: true });
      const { instance } = await WebAssembly.instantiate(wasmBytes, importObject);
      wasmInstance = instance;

      updateLoader(96, "Starting AdaEngine…");
      swift.setInstance(instance);
      bridgeJS.setInstance(instance);
      bridgeJS.createExports(instance);
      wasi.initialize(instance);
      swift.main();
      hideLoader();
    }

    run().catch(failLoader);
    """
}

private func packageJSON(product: String) -> String {
    """
    {
      "name": "\(product.lowercased())-ada-web",
      "private": true,
      "type": "module",
      "scripts": {
        "serve": "vite --host 127.0.0.1"
      },
      "dependencies": {
        "@bjorn3/browser_wasi_shim": "^0.4.1",
        "vite": "^5.0.0"
      },
      "devDependencies": {}
    }
    """
}

private func manifestJSON(product: String) -> String {
    """
    {
      "product": "\(product)",
      "wasm": "\(product).wasm",
      "canvasRoot": "ada-canvas-root",
      "assets": "Assets"
    }
    """
}
