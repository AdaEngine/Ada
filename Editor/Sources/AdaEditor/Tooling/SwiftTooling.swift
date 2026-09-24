@preconcurrency import Foundation
import GravityLanguageCore

struct SwiftToolchain: Equatable, Sendable {
    var swiftExecutablePath: String
    var sourceKitLSPExecutablePath: String?

    var hasSourceKitLSP: Bool {
        sourceKitLSPExecutablePath != nil
    }
}

enum SwiftToolchainLocator {
    static func locate(fileManager: FileManager = .default) async -> SwiftToolchain {
        let swiftPath = await findExecutable(["/usr/bin/swift", "/usr/local/bin/swift"], fallbackName: "swift", fileManager: fileManager) ?? "swift"
        let sourceKitPath = await findSourceKitLSP(fileManager: fileManager)

        return SwiftToolchain(
            swiftExecutablePath: swiftPath,
            sourceKitLSPExecutablePath: sourceKitPath
        )
    }

    private static func findSourceKitLSP(fileManager: FileManager) async -> String? {
        #if os(macOS)
            if let xcrunPath = await runCapture(executable: "/usr/bin/xcrun", arguments: ["--find", "sourcekit-lsp"]),
                fileManager.isExecutableFile(atPath: xcrunPath) {
                return xcrunPath
            }
        #endif

        return await findExecutable(
            [
                "/usr/bin/sourcekit-lsp",
                "/usr/local/bin/sourcekit-lsp",
                "/opt/homebrew/bin/sourcekit-lsp",
            ],
            fallbackName: "sourcekit-lsp",
            fileManager: fileManager
        )
    }

    private static func findExecutable(_ candidates: [String], fallbackName: String, fileManager: FileManager) async -> String? {
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        #if os(Windows)
            let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#
            let whereExecutable = URL(fileURLWithPath: systemRoot, isDirectory: true)
                .appendingPathComponent("System32/where.exe")
                .path
            return await runCapture(executable: whereExecutable, arguments: [fallbackName])
        #else
            return await runCapture(executable: "/usr/bin/env", arguments: ["which", fallbackName])
        #endif
    }

    private static func runCapture(executable: String, arguments: [String]) async -> String? {
        #if os(macOS) || os(Linux) || os(Windows)
            await withCheckedContinuation { continuation in
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = Pipe()
                process.terminationHandler = { process in
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    let value = String(bytes: data, encoding: .utf8)?
                        .split(whereSeparator: \Character.isNewline)
                        .first
                        .map(String.init)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: process.terminationStatus == 0 && value?.isEmpty == false ? value : nil)
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        #else
            nil
        #endif
    }
}

struct EditorProcessCommand: Equatable, Sendable {
    var executablePath: String
    var arguments: [String]
    var workingDirectory: URL
    var environment: [String: String]
    var displayName: String

    init(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String] = [:],
        displayName: String? = nil
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.displayName = displayName ?? ([URL(fileURLWithPath: executablePath).lastPathComponent] + arguments).joined(separator: " ")
    }

    var shellDescription: String {
        displayName
    }
}

enum EditorProcessOutputStream: Equatable, Sendable {
    case standardOutput
    case standardError
}

struct EditorProcessOutputEvent: Equatable, Sendable {
    var stream: EditorProcessOutputStream
    var text: String
}

enum SwiftPMWorkspaceBootstrapPhase: String, Equatable, Sendable {
    case loadingProjectMetadata
    case locatingToolchain
    case resolvingDependencies
    case describingPackage
    case startingSourceKitLSP
    case scanningSources
    case indexingBuild
    case ready
    case failed
}

struct SwiftPMWorkspaceProgress: Equatable, Sendable {
    var phase: SwiftPMWorkspaceBootstrapPhase
    var title: String
    var detail: String?
    var completedFileCount: Int?
    var totalFileCount: Int?
    var currentFile: String?
    var currentTarget: String?
    var command: EditorProcessCommand?

    init(
        phase: SwiftPMWorkspaceBootstrapPhase,
        title: String,
        detail: String? = nil,
        completedFileCount: Int? = nil,
        totalFileCount: Int? = nil,
        currentFile: String? = nil,
        currentTarget: String? = nil,
        command: EditorProcessCommand? = nil
    ) {
        self.phase = phase
        self.title = title
        self.detail = detail
        self.completedFileCount = completedFileCount
        self.totalFileCount = totalFileCount
        self.currentFile = currentFile
        self.currentTarget = currentTarget
        self.command = command
    }

    var progressText: String {
        var value = title
        if let completedFileCount, let totalFileCount, totalFileCount > 0 {
            value += " \(completedFileCount)/\(totalFileCount)"
        }
        if let currentFile, !currentFile.isEmpty {
            value += " — \(currentFile)"
        }
        return value
    }
}

struct SwiftPMBuildProgressParser: Sendable {
    private(set) var completedFiles: Set<String> = []

    mutating func parse(line: String, knownFiles: [URL]) -> SwiftPMBuildProgress {
        let file = Self.swiftFileName(in: line)
        if let file {
            if let knownFile = knownFiles.first(where: { $0.lastPathComponent == file || $0.path.hasSuffix(file) }) {
                completedFiles.insert(knownFile.path)
            } else {
                completedFiles.insert(file)
            }
        }
        return SwiftPMBuildProgress(completed: completedFiles.count, currentFile: file, currentTarget: Self.targetName(in: line))
    }

    static func swiftFileName(in line: String) -> String? {
        let components = line.split { $0 == " " || $0 == "\t" || $0 == ":" || $0 == "(" || $0 == ")" }
        return components.map(String.init).first { $0.hasSuffix(".swift") }
    }

    static func targetName(in line: String) -> String? {
        let tokens = line.split { $0 == " " || $0 == "\t" }.map(String.init)
        guard let compilingIndex = tokens.firstIndex(of: "Compiling"), tokens.indices.contains(tokens.index(after: compilingIndex)) else {
            return nil
        }
        let candidate = tokens[tokens.index(after: compilingIndex)]
        return candidate.hasSuffix(".swift") ? nil : candidate
    }
}

struct SwiftPMBuildProgress: Equatable, Sendable {
    var completed: Int
    var currentFile: String?
    var currentTarget: String?
}

struct SwiftPMIndexingProgressBatch: Equatable, Sendable {
    var lines: [String]
    var buildProgress: SwiftPMBuildProgress
}

actor SwiftPMBuildProgressTracker {
    private var parser = SwiftPMBuildProgressParser()
    private var pendingStandardOutput = ""
    private var pendingStandardError = ""
    private var pendingLines: [String] = []
    private var latestProgress = SwiftPMBuildProgress(completed: 0, currentFile: nil, currentTarget: nil)
    private let minimumEmissionInterval: TimeInterval
    private var lastEmissionTime: TimeInterval

    init(
        minimumEmissionInterval: TimeInterval = 0.5,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        self.minimumEmissionInterval = max(0, minimumEmissionInterval)
        self.lastEmissionTime = now
    }

    func consume(
        _ event: EditorProcessOutputEvent,
        knownFiles: [URL],
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) -> SwiftPMIndexingProgressBatch? {
        consume(lines: completeLines(from: event), knownFiles: knownFiles)
        guard now - lastEmissionTime >= minimumEmissionInterval else {
            return nil
        }
        return drain(now: now)
    }

    func finish(
        knownFiles: [URL],
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) -> SwiftPMIndexingProgressBatch? {
        let trailingLines = [pendingStandardOutput, pendingStandardError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        pendingStandardOutput = ""
        pendingStandardError = ""
        consume(lines: trailingLines, knownFiles: knownFiles)
        return drain(now: now)
    }

    private func completeLines(from event: EditorProcessOutputEvent) -> [String] {
        let pending =
            switch event.stream {
            case .standardOutput: pendingStandardOutput
            case .standardError: pendingStandardError
            }
        let combined = pending + event.text
        let lines = combined.components(separatedBy: .newlines)
        let endsWithNewline = combined.last?.isNewline == true
        let completeLineCount = endsWithNewline ? lines.count : max(0, lines.count - 1)

        switch event.stream {
        case .standardOutput:
            pendingStandardOutput = endsWithNewline ? "" : lines.last ?? ""
        case .standardError:
            pendingStandardError = endsWithNewline ? "" : lines.last ?? ""
        }

        return lines.prefix(completeLineCount)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func consume(lines: [String], knownFiles: [URL]) {
        for line in lines {
            let parsed = parser.parse(line: line, knownFiles: knownFiles)
            latestProgress = SwiftPMBuildProgress(
                completed: parsed.completed,
                currentFile: parsed.currentFile ?? latestProgress.currentFile,
                currentTarget: parsed.currentTarget ?? latestProgress.currentTarget
            )
            pendingLines.append(line)
        }
    }

    private func drain(now: TimeInterval) -> SwiftPMIndexingProgressBatch? {
        guard !pendingLines.isEmpty else {
            return nil
        }
        let batch = SwiftPMIndexingProgressBatch(lines: pendingLines, buildProgress: latestProgress)
        pendingLines.removeAll(keepingCapacity: true)
        lastEmissionTime = now
        return batch
    }
}

struct EditorProcessResult: Equatable, Sendable {
    var command: EditorProcessCommand
    var exitCode: Int32
    var standardOutput: String
    var standardError: String

    var succeeded: Bool {
        exitCode == 0
    }

    var combinedOutput: String {
        [standardOutput, standardError]
            .filter { !$0.isEmpty }
            .joined(separator: standardOutput.isEmpty || standardError.isEmpty ? "" : "\n")
    }
}

protocol EditorProcessRunning: Sendable {
    func run(_ command: EditorProcessCommand) async -> EditorProcessResult
    func run(_ command: EditorProcessCommand, output: @Sendable @escaping (EditorProcessOutputEvent) async -> Void) async -> EditorProcessResult
    func cancelAll() async
}

extension EditorProcessRunning {
    func run(_ command: EditorProcessCommand, output _: @Sendable @escaping (EditorProcessOutputEvent) async -> Void) async -> EditorProcessResult {
        await run(command)
    }
}

#if os(macOS) || os(Linux) || os(Windows)
    actor EditorProcessRunner: EditorProcessRunning {
        private var activeProcesses: [UUID: Process] = [:]

        func run(_ command: EditorProcessCommand) async -> EditorProcessResult {
            await run(command) { _ in }
        }

        func run(_ command: EditorProcessCommand, output outputHandler: @Sendable @escaping (EditorProcessOutputEvent) async -> Void) async -> EditorProcessResult {
            let processID = UUID()
            let process = Process()
            let output = Pipe()
            let error = Pipe()

            process.executableURL = URL(fileURLWithPath: command.executablePath)
            process.arguments = command.arguments
            process.currentDirectoryURL = command.workingDirectory
            process.standardOutput = output
            process.standardError = error
            process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }

            activeProcesses[processID] = process
            defer { activeProcesses[processID] = nil }

            let terminationEvents = AsyncStream<Void> { continuation in
                process.terminationHandler = { _ in
                    continuation.yield(())
                    continuation.finish()
                }
            }

            do {
                try process.run()
            } catch {
                return EditorProcessResult(
                    command: command,
                    exitCode: 127,
                    standardOutput: "",
                    standardError: error.localizedDescription
                )
            }

            async let standardOutput = Self.collectOutput(from: output, stream: .standardOutput, output: outputHandler)
            async let standardError = Self.collectOutput(from: error, stream: .standardError, output: outputHandler)
            for await _ in terminationEvents {
                break
            }

            return await EditorProcessResult(
                command: command,
                exitCode: process.terminationStatus,
                standardOutput: standardOutput,
                standardError: standardError
            )
        }

        nonisolated private static func collectOutput(
            from pipe: Pipe,
            stream: EditorProcessOutputStream,
            output: @Sendable @escaping (EditorProcessOutputEvent) async -> Void
        ) async -> String {
            let handle = pipe.fileHandleForReading
            let chunks = AsyncStream<Data> { continuation in
                handle.readabilityHandler = { readableHandle in
                    let data = readableHandle.availableData
                    guard !data.isEmpty else {
                        readableHandle.readabilityHandler = nil
                        continuation.finish()
                        return
                    }
                    continuation.yield(data)
                }
            }
            defer { handle.readabilityHandler = nil }

            var collected = Data()
            for await data in chunks {
                collected.append(data)
                if let text = String(bytes: data, encoding: .utf8), !text.isEmpty {
                    await output(EditorProcessOutputEvent(stream: stream, text: text))
                }
            }
            return String(bytes: collected, encoding: .utf8) ?? ""
        }

        func cancelAll() {
            for process in activeProcesses.values where process.isRunning {
                process.terminate()
            }
        }
    }
#else
    actor EditorProcessRunner: EditorProcessRunning {
        func run(_ command: EditorProcessCommand) async -> EditorProcessResult {
            EditorProcessResult(
                command: command,
                exitCode: 126,
                standardOutput: "",
                standardError: "External processes are unavailable on this platform."
            )
        }

        func cancelAll() {}
    }
#endif

enum SwiftPMCommandKind: Equatable, Sendable {
    case resolve
    case describe
    case build(target: String?, buildTests: Bool)
    case run(target: String?, arguments: [String])
    case runWeb(target: String, outputPath: String, serve: Bool)
    case test(filter: String?)
    case update
    case clean
    case reset
}

enum EditorRunDestination: String, CaseIterable, Equatable, Sendable {
    case player = "AdaPlayer"
    case macOS = "macOS"
    case iPadOS = "iPadOS"
    case web = "Web"
}

struct SwiftPackageModel: Equatable, Sendable {
    var name: String
    var products: [SwiftPackageProduct]
    var targets: [SwiftPackageTarget]
    var dependencies: [SwiftPackageDependency]

    var executableTargets: [String] {
        executableProducts.flatMap(\.targets)
    }

    var executableProducts: [SwiftPackageProduct] {
        products.filter { $0.type == "executable" }
    }

    func executableTargetName(forProductNamed productName: String) -> String? {
        guard let product = executableProducts.first(where: { $0.name == productName }), product.targets.count == 1 else {
            return nil
        }
        return product.targets[0]
    }

    var testTargets: [String] {
        targets.filter { $0.type == "test" }.map(\.name)
    }

    var pluginTargets: [String] {
        targets.filter { $0.type == "plugin" }.map(\.name)
    }
}

struct SwiftPackageProduct: Equatable, Sendable {
    var name: String
    var type: String
    var targets: [String]
}

struct SwiftPackageTarget: Equatable, Sendable {
    var name: String
    var type: String
    var path: String?
    var sources: [String]
    var targetDependencies: [String]
    var productDependencies: [String]
}

struct SwiftPackageDependency: Equatable, Sendable {
    var identity: String
    var type: String
    var url: String?
    var path: String?
    var requirement: String?
}

struct SwiftPMBootstrapResult: Equatable, Sendable {
    var toolchain: SwiftToolchain
    var resolveResult: EditorProcessResult
    var packageModel: SwiftPackageModel?
    var describeResult: EditorProcessResult
    var indexBuildResult: EditorProcessResult?
    var diagnostics: [EditorDiagnostic]

    var succeeded: Bool {
        resolveResult.succeeded && describeResult.succeeded
    }
}

struct EditorAdaScriptSourceAnalysis: Sendable {
    var diagnostics: [EditorDiagnostic]
    var semanticTokens: [EditorSemanticToken]
}

protocol SwiftPMWorkspaceServicing: Sendable {
    func makeCommand(_ kind: SwiftPMCommandKind, projectURL: URL, toolchain: SwiftToolchain) -> EditorProcessCommand
    func bootstrap(projectURL: URL) async -> SwiftPMBootstrapResult
    func bootstrap(projectURL: URL, progress: @Sendable @escaping (SwiftPMWorkspaceProgress) async -> Void) async -> SwiftPMBootstrapResult
    func execute(_ kind: SwiftPMCommandKind, projectURL: URL) async -> EditorProcessResult
    func execute(
        _ kind: SwiftPMCommandKind,
        projectURL: URL,
        output: @Sendable @escaping (EditorProcessOutputEvent) async -> Void
    ) async -> EditorProcessResult
    func semanticTokens(fileURL: URL, language: EditorSourceLanguage, text: String) async -> [EditorSemanticToken]
    func adaScriptAnalysis(fileURL: URL, text: String) async -> EditorAdaScriptSourceAnalysis
    func completions(fileURL: URL, language: EditorSourceLanguage, text: String, position: EditorSourceLocation) async -> [EditorCompletionItem]
    func definition(fileURL: URL, language: EditorSourceLanguage, text: String, position: EditorSourceLocation) async -> [EditorSourceSymbolTarget]
    func references(fileURL: URL, language: EditorSourceLanguage, text: String, position: EditorSourceLocation) async -> [EditorSourceReference]
    func hover(fileURL: URL, language: EditorSourceLanguage, text: String, position: EditorSourceLocation) async -> EditorSymbolHover?
    func documentHighlights(fileURL: URL, language: EditorSourceLanguage, text: String, position: EditorSourceLocation) async -> [EditorDocumentHighlight]
    func setDiagnosticsHandler(_ handler: @Sendable @escaping (String, [EditorDiagnostic]) async -> Void) async
    func configureSourceWorkspace(projectURL: URL) async
    func cancel() async
}

extension SwiftPMWorkspaceServicing {
    func adaScriptAnalysis(fileURL: URL, text: String) async -> EditorAdaScriptSourceAnalysis {
        EditorAdaScriptSourceAnalysis(
            diagnostics: [],
            semanticTokens: await semanticTokens(fileURL: fileURL, language: .ada, text: text)
        )
    }

    func bootstrap(projectURL: URL, progress _: @Sendable @escaping (SwiftPMWorkspaceProgress) async -> Void) async -> SwiftPMBootstrapResult {
        await bootstrap(projectURL: projectURL)
    }

    func execute(
        _ kind: SwiftPMCommandKind,
        projectURL: URL,
        output _: @Sendable @escaping (EditorProcessOutputEvent) async -> Void
    ) async -> EditorProcessResult {
        await execute(kind, projectURL: projectURL)
    }

    func completions(fileURL _: URL, language _: EditorSourceLanguage, text _: String, position _: EditorSourceLocation) async -> [EditorCompletionItem] {
        []
    }

    func setDiagnosticsHandler(_: @Sendable @escaping (String, [EditorDiagnostic]) async -> Void) async {}

    func configureSourceWorkspace(projectURL _: URL) async {}
}

actor SwiftPMWorkspaceService: SwiftPMWorkspaceServicing {
    static let responsiveBuildJobCount = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))

    private let processRunner: any EditorProcessRunning
    private let gravityWorkspace = GravityWorkspace()
    private var sourceWorkspaceURL: URL?
    private var toolchain: SwiftToolchain?
    private var sourceKitClient: SourceKitLSPClient?
    private var diagnosticsHandler: (@Sendable (String, [EditorDiagnostic]) async -> Void)?

    init(
        processRunner: any EditorProcessRunning = EditorProcessRunner(),
        sourceKitClient: SourceKitLSPClient? = nil,
        toolchain: SwiftToolchain? = nil
    ) {
        self.processRunner = processRunner
        self.sourceKitClient = sourceKitClient
        self.toolchain = toolchain
    }

    nonisolated func makeCommand(_ kind: SwiftPMCommandKind, projectURL: URL, toolchain: SwiftToolchain) -> EditorProcessCommand {
        let arguments: [String] =
            switch kind {
            case .resolve:
                ["package", "resolve"]
            case .describe:
                ["package", "describe", "--type", "json"]
            case let .build(target, buildTests):
                buildArguments(target: target, buildTests: buildTests)
            case let .run(target, arguments):
                runArguments(target: target, runArguments: arguments)
            case let .runWeb(target, outputPath, serve):
                webRunArguments(target: target, outputPath: outputPath, serve: serve)
            case let .test(filter):
                testArguments(filter: filter)
            case .update:
                ["package", "update"]
            case .clean:
                ["package", "clean"]
            case .reset:
                ["package", "reset"]
            }

        let environment: [String: String] =
            if case .runWeb = kind {
                ["ADAENGINE_WEB_EXPORT": "1", "BUILD_WASM": "1"]
            } else {
                [:]
            }
        return EditorProcessCommand(
            executablePath: toolchain.swiftExecutablePath,
            arguments: arguments,
            workingDirectory: projectURL,
            environment: environment
        )
    }

    func bootstrap(projectURL: URL) async -> SwiftPMBootstrapResult {
        await bootstrap(projectURL: projectURL) { _ in }
    }

    func bootstrap(projectURL: URL, progress: @Sendable @escaping (SwiftPMWorkspaceProgress) async -> Void) async -> SwiftPMBootstrapResult {
        guard EditorDistribution.current.supportsSwiftProjects else {
            let result = unavailableResult(projectURL: projectURL)
            return SwiftPMBootstrapResult(
                toolchain: SwiftToolchain(swiftExecutablePath: "", sourceKitLSPExecutablePath: nil),
                resolveResult: result,
                packageModel: nil,
                describeResult: result,
                diagnostics: []
            )
        }
        await configureSourceWorkspace(projectURL: projectURL)
        await progress(SwiftPMWorkspaceProgress(phase: .loadingProjectMetadata, title: "Loading project metadata", detail: projectURL.path))
        await progress(SwiftPMWorkspaceProgress(phase: .locatingToolchain, title: "Locating Swift toolchain", detail: "Searching swift and sourcekit-lsp"))
        let resolvedToolchain =
            if let toolchain {
                toolchain
            } else {
                await SwiftToolchainLocator.locate()
            }
        toolchain = resolvedToolchain
        await progress(
            SwiftPMWorkspaceProgress(
                phase: .locatingToolchain,
                title: "Swift toolchain found",
                detail: "swift: \(resolvedToolchain.swiftExecutablePath), sourcekit-lsp: \(resolvedToolchain.sourceKitLSPExecutablePath ?? "unavailable")"
            )
        )

        let resolveCommand = makeCommand(.resolve, projectURL: projectURL, toolchain: resolvedToolchain)
        await progress(SwiftPMWorkspaceProgress(phase: .resolvingDependencies, title: "Resolving SwiftPM dependencies", command: resolveCommand))
        let resolveResult = await processRunner.run(resolveCommand) { event in
            await progress(
                SwiftPMWorkspaceProgress(
                    phase: .resolvingDependencies,
                    title: "Resolving SwiftPM dependencies",
                    detail: event.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    command: resolveCommand
                )
            )
        }

        let describeCommand = makeCommand(.describe, projectURL: projectURL, toolchain: resolvedToolchain)
        await progress(SwiftPMWorkspaceProgress(phase: .describingPackage, title: "Reading SwiftPM package graph", command: describeCommand))
        let describeResult =
            resolveResult.succeeded
            ? await processRunner.run(describeCommand)
            : EditorProcessResult(command: describeCommand, exitCode: 1, standardOutput: "", standardError: "Skipped because dependency resolution failed.")
        let packageModel = describeResult.succeeded ? SwiftPackageModel.parse(from: describeResult.standardOutput) : nil

        let indexBuildResult: EditorProcessResult?
        if resolveResult.succeeded && describeResult.succeeded {
            indexBuildResult = await buildWorkspaceIndex(
                projectURL: projectURL,
                packageModel: packageModel,
                toolchain: resolvedToolchain,
                progress: progress
            )
        } else {
            indexBuildResult = nil
        }

        if resolveResult.succeeded && describeResult.succeeded {
            let lspTitle = resolvedToolchain.hasSourceKitLSP ? "Starting SourceKit-LSP" : "SourceKit-LSP unavailable"
            await progress(SwiftPMWorkspaceProgress(phase: .startingSourceKitLSP, title: lspTitle, detail: resolvedToolchain.sourceKitLSPExecutablePath))
            await startSourceKitLSPIfAvailable(toolchain: resolvedToolchain, projectURL: projectURL)
        }

        let diagnostics = [resolveResult, describeResult, indexBuildResult]
            .compactMap { $0 }
            .flatMap { EditorDiagnostic.diagnostics(from: $0, projectURL: projectURL) }

        await progress(
            SwiftPMWorkspaceProgress(
                phase: (resolveResult.succeeded && describeResult.succeeded && indexBuildResult?.succeeded != false) ? .ready : .failed,
                title: (resolveResult.succeeded && describeResult.succeeded && indexBuildResult?.succeeded != false) ? "Workspace ready" : "Workspace bootstrap failed"
            )
        )

        return SwiftPMBootstrapResult(
            toolchain: resolvedToolchain,
            resolveResult: resolveResult,
            packageModel: packageModel,
            describeResult: describeResult,
            indexBuildResult: indexBuildResult,
            diagnostics: diagnostics
        )
    }

    private func unavailableResult(projectURL: URL) -> EditorProcessResult {
        EditorProcessResult(
            command: EditorProcessCommand(executablePath: "", arguments: [], workingDirectory: projectURL, displayName: "SwiftPM"),
            exitCode: 1,
            standardOutput: "",
            standardError: EditorDistributionError.swiftProjectsMessage
        )
    }

    private func buildWorkspaceIndex(
        projectURL: URL,
        packageModel: SwiftPackageModel?,
        toolchain: SwiftToolchain,
        progress: @Sendable @escaping (SwiftPMWorkspaceProgress) async -> Void
    ) async -> EditorProcessResult {
        let sourceFiles = Self.swiftSourceFiles(projectURL: projectURL, packageModel: packageModel, includeTests: false, fileManager: .default)
        await progress(
            SwiftPMWorkspaceProgress(
                phase: .scanningSources,
                title: "Scanning Swift source files",
                completedFileCount: 0,
                totalFileCount: sourceFiles.count
            )
        )
        await progress(
            SwiftPMWorkspaceProgress(
                phase: .scanningSources,
                title: "Scanned Swift source files",
                completedFileCount: sourceFiles.count,
                totalFileCount: sourceFiles.count
            )
        )

        let buildCommand = makeCommand(.build(target: nil, buildTests: false), projectURL: projectURL, toolchain: toolchain)
        await progress(
            SwiftPMWorkspaceProgress(
                phase: .indexingBuild,
                title: "Indexing Swift package",
                completedFileCount: 0,
                totalFileCount: sourceFiles.count,
                command: buildCommand
            )
        )

        let progressTracker = SwiftPMBuildProgressTracker()
        let result = await processRunner.run(buildCommand) { event in
            if let batch = await progressTracker.consume(event, knownFiles: sourceFiles) {
                await progress(Self.indexingProgress(batch: batch, sourceFiles: sourceFiles, command: buildCommand))
            }
        }
        if let batch = await progressTracker.finish(knownFiles: sourceFiles) {
            await progress(Self.indexingProgress(batch: batch, sourceFiles: sourceFiles, command: buildCommand))
        }
        return result
    }

    func execute(_ kind: SwiftPMCommandKind, projectURL: URL) async -> EditorProcessResult {
        await execute(kind, projectURL: projectURL) { _ in }
    }

    func execute(
        _ kind: SwiftPMCommandKind,
        projectURL: URL,
        output: @Sendable @escaping (EditorProcessOutputEvent) async -> Void
    ) async -> EditorProcessResult {
        guard EditorDistribution.current.supportsSwiftProjects else {
            return unavailableResult(projectURL: projectURL)
        }
        let resolvedToolchain: SwiftToolchain
        if let toolchain {
            resolvedToolchain = toolchain
        } else {
            resolvedToolchain = await SwiftToolchainLocator.locate()
            toolchain = resolvedToolchain
        }

        return await processRunner.run(
            makeCommand(kind, projectURL: projectURL, toolchain: resolvedToolchain),
            output: output
        )
    }

    func cancel() async {
        await processRunner.cancelAll()
    }

    func setDiagnosticsHandler(_ handler: @Sendable @escaping (String, [EditorDiagnostic]) async -> Void) {
        diagnosticsHandler = handler
    }

    func configureSourceWorkspace(projectURL: URL) async {
        let root = projectURL.standardizedFileURL
        guard root != sourceWorkspaceURL else {
            return
        }
        sourceWorkspaceURL = root
        gravityWorkspace.configure(rootURIs: [root.absoluteString])
    }

    func semanticTokens(fileURL: URL, language: EditorSourceLanguage, text: String) async -> [EditorSemanticToken] {
        if language == .ada {
            let diagnostics = EditorGravityLanguageService.diagnostics(workspace: gravityWorkspace, fileURL: fileURL, text: text)
            await diagnosticsHandler?(fileURL.standardizedFileURL.absoluteString, diagnostics)
            return EditorGravityLanguageService.semanticTokens(text: text)
        }
        guard let sourceKitClient else {
            return []
        }

        do {
            try await sourceKitClient.openDocument(fileURL: fileURL, language: language, text: text)
            return try await sourceKitClient.refreshSemanticTokens(fileURL: fileURL)
        } catch {
            return []
        }
    }

    func adaScriptAnalysis(fileURL: URL, text: String) async -> EditorAdaScriptSourceAnalysis {
        EditorAdaScriptSourceAnalysis(
            diagnostics: EditorGravityLanguageService.diagnostics(workspace: gravityWorkspace, fileURL: fileURL, text: text),
            semanticTokens: EditorGravityLanguageService.semanticTokens(text: text)
        )
    }

    func completions(fileURL: URL, language: EditorSourceLanguage, text: String, position: EditorSourceLocation) async -> [EditorCompletionItem] {
        if language == .ada {
            return EditorGravityLanguageService.completions(
                workspace: gravityWorkspace,
                uri: fileURL.standardizedFileURL.absoluteString,
                text: text,
                position: position
            )
        }

        guard let sourceKitClient else {
            return []
        }

        do {
            try await sourceKitClient.openDocument(fileURL: fileURL, language: language, text: text)
            return try await sourceKitClient.completion(fileURL: fileURL, position: position)
        } catch {
            return []
        }
    }

    func definition(fileURL: URL, language: EditorSourceLanguage, text: String, position: EditorSourceLocation) async -> [EditorSourceSymbolTarget] {
        if language == .ada {
            return
                EditorGravityLanguageService.definition(
                    workspace: gravityWorkspace,
                    uri: fileURL.standardizedFileURL.absoluteString,
                    text: text,
                    position: position
                )
                .map { [$0] } ?? []
        }
        guard let sourceKitClient else {
            return []
        }

        do {
            try await sourceKitClient.openDocument(fileURL: fileURL, language: language, text: text)
            return try await sourceKitClient.definition(fileURL: fileURL, position: position)
        } catch {
            return []
        }
    }

    func references(fileURL: URL, language: EditorSourceLanguage, text: String, position: EditorSourceLocation) async -> [EditorSourceReference] {
        guard let sourceKitClient else {
            return []
        }

        do {
            try await sourceKitClient.openDocument(fileURL: fileURL, language: language, text: text)
            return try await sourceKitClient.references(fileURL: fileURL, position: position)
        } catch {
            return []
        }
    }

    func hover(fileURL: URL, language: EditorSourceLanguage, text: String, position: EditorSourceLocation) async -> EditorSymbolHover? {
        if language == .ada {
            return EditorGravityLanguageService.hover(
                workspace: gravityWorkspace,
                uri: fileURL.standardizedFileURL.absoluteString,
                text: text,
                position: position
            )
        }
        guard let sourceKitClient else {
            return nil
        }

        do {
            try await sourceKitClient.openDocument(fileURL: fileURL, language: language, text: text)
            return try await sourceKitClient.hover(fileURL: fileURL, position: position)
        } catch {
            return nil
        }
    }

    func documentHighlights(fileURL: URL, language: EditorSourceLanguage, text: String, position: EditorSourceLocation) async -> [EditorDocumentHighlight] {
        if language == .ada {
            return []
        }
        guard let sourceKitClient else {
            return []
        }

        do {
            try await sourceKitClient.openDocument(fileURL: fileURL, language: language, text: text)
            return try await sourceKitClient.documentHighlights(fileURL: fileURL, position: position)
        } catch {
            return []
        }
    }

    nonisolated private func buildArguments(target: String?, buildTests: Bool) -> [String] {
        var arguments = ["build", "--jobs", String(Self.responsiveBuildJobCount)]
        if buildTests {
            arguments.append("--build-tests")
        }
        if let target, !target.isEmpty {
            arguments += ["--target", target]
        }
        return arguments
    }

    nonisolated private func runArguments(target: String?, runArguments: [String]) -> [String] {
        var arguments = ["run"]
        if let target, !target.isEmpty {
            arguments.append(target)
        }
        if !runArguments.isEmpty {
            arguments.append("--")
            arguments += runArguments
        }
        return arguments
    }

    nonisolated private func webRunArguments(target: String, outputPath: String, serve: Bool) -> [String] {
        var arguments = [
            "package",
            "--allow-writing-to-package-directory",
            "--allow-network-connections", "all",
            "export-web",
            "--product", target,
            "--output", outputPath,
        ]
        if serve {
            arguments.append("--serve")
        }
        return arguments
    }

    nonisolated private func testArguments(filter: String?) -> [String] {
        var arguments = ["test", "--parallel"]
        if let filter, !filter.isEmpty {
            arguments += ["--filter", filter]
        }
        return arguments
    }

    static func swiftSourceFiles(
        projectURL: URL,
        packageModel: SwiftPackageModel?,
        includeTests: Bool = true,
        fileManager: FileManager = .default
    ) -> [URL] {
        var files: Set<URL> = []
        if let packageModel {
            for target in packageModel.targets where includeTests || target.type != "test" {
                let targetRoot = projectURL.appendingPathComponent(target.path ?? "Sources/\(target.name)", isDirectory: true)
                if target.sources.isEmpty {
                    for file in swiftFiles(under: targetRoot, fileManager: fileManager) {
                        files.insert(file.standardizedFileURL)
                    }
                } else {
                    for source in target.sources where source.hasSuffix(".swift") {
                        files.insert(targetRoot.appendingPathComponent(source, isDirectory: false).standardizedFileURL)
                    }
                }
            }
        }

        if files.isEmpty {
            let directories = includeTests ? ["Sources", "Tests"] : ["Sources"]
            for directory in directories {
                files.formUnion(swiftFiles(under: projectURL.appendingPathComponent(directory, isDirectory: true), fileManager: fileManager).map(\.standardizedFileURL))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func swiftFiles(under root: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else {
                return nil
            }
            return url
        }
    }

    nonisolated private static func indexingProgress(
        batch: SwiftPMIndexingProgressBatch,
        sourceFiles: [URL],
        command: EditorProcessCommand
    ) -> SwiftPMWorkspaceProgress {
        SwiftPMWorkspaceProgress(
            phase: .indexingBuild,
            title: "Indexing Swift package",
            detail: batch.lines.joined(separator: "\n"),
            completedFileCount: batch.buildProgress.completed,
            totalFileCount: sourceFiles.count,
            currentFile: batch.buildProgress.currentFile,
            currentTarget: batch.buildProgress.currentTarget,
            command: command
        )
    }

    private func startSourceKitLSPIfAvailable(toolchain: SwiftToolchain, projectURL: URL) async {
        guard toolchain.sourceKitLSPExecutablePath != nil else {
            return
        }

        let client = SourceKitLSPClient(connection: SourceKitLSPStdioConnection())
        do {
            await client.setDiagnosticsHandler { [weak self] uri, diagnostics in
                await self?.diagnosticsHandler?(uri, diagnostics)
            }
            try await client.start(toolchain: toolchain, projectURL: projectURL)
            sourceKitClient = client
        } catch {
            await client.stop()
        }
    }
}

extension SwiftPackageModel {
    static func parse(from json: String) -> SwiftPackageModel? {
        guard let data = json.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(SwiftPackageDescription.self, from: data).model
    }
}

private struct SwiftPackageDescription: Decodable {
    var name: String
    var products: [Product]
    var targets: [Target]
    var dependencies: [Dependency]

    var model: SwiftPackageModel {
        SwiftPackageModel(
            name: name,
            products: products.map(\.model),
            targets: targets.map(\.model),
            dependencies: dependencies.map(\.model)
        )
    }

    struct Product: Decodable {
        var name: String
        var targets: [String]
        var type: JSONValue

        var model: SwiftPackageProduct {
            SwiftPackageProduct(name: name, type: type.objectKeys.first ?? "unknown", targets: targets)
        }
    }

    struct Target: Decodable {
        var name: String
        var type: String
        var path: String?
        var sources: [String]?
        var targetDependencies: [String]?
        var productDependencies: [String]?

        private enum CodingKeys: String, CodingKey {
            case name, type, path, sources
            case targetDependencies = "target_dependencies"
            case productDependencies = "product_dependencies"
        }

        var model: SwiftPackageTarget {
            SwiftPackageTarget(
                name: name,
                type: type,
                path: path,
                sources: sources ?? [],
                targetDependencies: targetDependencies ?? [],
                productDependencies: productDependencies ?? []
            )
        }
    }

    struct Dependency: Decodable {
        var identity: String
        var type: String?
        var url: String?
        var path: String?
        var requirement: JSONValue?

        var model: SwiftPackageDependency {
            SwiftPackageDependency(
                identity: identity,
                type: type ?? (path == nil ? "sourceControl" : "fileSystem"),
                url: url,
                path: path,
                requirement: requirement?.compactDescription
            )
        }
    }
}

private enum JSONValue: Decodable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([Self])
    case object([String: Self])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: Self].self))
        }
    }

    var objectKeys: [String] {
        guard case let .object(object) = self else {
            return []
        }
        return object.keys.sorted()
    }

    var compactDescription: String {
        switch self {
        case let .string(value):
            value
        case let .number(value):
            String(value)
        case let .bool(value):
            String(value)
        case let .array(values):
            values.map(\.compactDescription).joined(separator: ",")
        case let .object(object):
            object.keys.sorted().map { "\($0):\(object[$0]?.compactDescription ?? "")" }.joined(separator: ",")
        case .null:
            "null"
        }
    }
}
