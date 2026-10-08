#if os(macOS)
import AdaEngine
import AdaScriptCompilerCore
import Darwin
import Dispatch
import Foundation

struct EditorCLIDiagnostic: Codable, Equatable, Sendable {
    var code: String
    var severity = "error"
    var message: String
    var file: String?
    /// One-based positions; column uses UTF-16, matching the editor's language services.
    var line: Int?
    var column: Int?
}

struct EditorCLIReport: Codable, Sendable {
    var schemaVersion = 1
    var cliVersion = "1.0.0"
    var command: String
    var ok = true
    var exitCode: Int32 = 0
    var diagnostics: [EditorCLIDiagnostic] = []
    var artifacts: [String] = []
    var details: [String: String] = [:]
    var project: AdaProject?

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// CLI mode exits before AppRuntime is initialized. No windows, recents or preferences are touched.
enum EditorCLI {
    static func isInvocation(_ arguments: [String]) -> Bool {
        arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent == "adastudio" } == true
            || arguments.dropFirst().first == "--ada-studio-cli"
    }

    static func run(arguments: [String]) async -> Int32 {
        var words = Array(arguments.dropFirst())
        if words.first == "--ada-studio-cli" { words.removeFirst() }
        let invocation: EditorCLIInvocation
        do {
            invocation = try EditorCLIInvocation(arguments: words)
        } catch {
            let report = failure(command: words.first ?? "help", error: error, fallbackCode: 2)
            let wantsJSON = zip(words, words.dropFirst()).contains { $0 == "--format" && $1 == "json" }
            emit(report, format: wantsJSON ? .json : .text)
            return report.exitCode
        }
        let runner = EditorProcessRunner()
        let task = Task {
            await execute(invocation, runner: runner) { event in
                try? FileHandle.standardError.write(contentsOf: Data(event.text.utf8))
            }
        }
        // The CLI owns signal handling for its lifetime. Cancel both the task and tool processes.
        let previous = signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler {
            task.cancel()
            Task { await runner.cancelAll() }
        }
        interrupt.resume()
        let report = await task.value
        interrupt.cancel()
        signal(SIGINT, previous)
        emit(report, format: invocation.format)
        return report.exitCode
    }

    static func execute(
        _ invocation: EditorCLIInvocation,
        runner: any EditorProcessRunning = EditorProcessRunner(),
        log: @Sendable @escaping (EditorProcessOutputEvent) async -> Void = { _ in }
    ) async -> EditorCLIReport {
        do {
            var report = EditorCLIReport(command: invocation.command.rawValue)
            switch invocation.command {
            case .help:
                report.details["help"] = EditorCLIInvocation.help
            case .version:
                report.details["version"] = report.cliVersion
            case .doctor:
                let sdk = try EditorBuildSDK.locate(override: invocation.options["sdk"])
                let swift = await swiftExecutable(for: invocation)
                try await checkTools(swift: swift, runner: runner, at: sdk.engineRoot)
                guard EditorDistribution.current.supportsSwiftProjects else {
                    throw EditorCLIError.environment("Native builds require the standalone macOS distribution of Ada Studio.")
                }
                report.details = [
                    "engine": sdk.engineRoot.path, "compiler": sdk.compilerRoot.path, "swift": swift,
                    "distribution": EditorDistribution.current.rawValue, "nativeTargets": "macos,web,android", "validation": "available"
                ]
            case .inspect, .validate, .build, .export:
                let root = invocation.projectURL
                let project = try ProjectSystem.validateProjectLayout(at: root)
                report.project = project
                report.details["projectPath"] = root.path
                if invocation.command == .inspect {
                    return report
                }
                try validateProjectPaths(project, at: root)
                if project.build.system.isAdaScript {
                    try preflightTypes(project, at: root)
                    let validation = try EditorAdaScriptProjectBuilder().build(project: project, at: root)
                    report.details["entry"] = validation.entryDescription
                    report.details["sourceCount"] = String(validation.sourceCount)
                    report.details["systemCount"] = String(validation.systemCount)
                    report.details["validationScope"] = "metadata,adascript,entry-scene,runtime-bindings"
                } else {
                    report.details["validationScope"] = "metadata,layout"
                }
                if invocation.command == .validate {
                    return report
                }
                if invocation.options["target"] == "android" {
                    let sdk = try EditorBuildSDK.locate(override: invocation.options["sdk"])
                    var configuration = EditorAndroidConfiguration.load(engineRoot: sdk.engineRoot)
                    for (option, key) in [("swift", "SWIFT_ANDROID_SWIFT"), ("swift-sdk", "SWIFT_ANDROID_SDK"), ("android-sdk", "ANDROID_HOME"),
                                          ("ndk", "ANDROID_NDK_HOME"), ("swift-sdks", "SWIFT_ANDROID_SDKS_PATH"), ("swan", "ADAENGINE_SWAN_PACKAGE_PATH"), ("dawn", "SWAN_LOCAL_DAWN")] {
                        if let value = invocation.options[option] { configuration.environment[key] = value }
                    }
                    try configuration.validateBuildTools(engineRoot: sdk.engineRoot)
                    let tools = EditorAndroidTools(runner: runner)
                    var serial = invocation.options["device"]
                    if let avd = invocation.options["emulator"] {
                        serial = try await tools.resolve(EditorAndroidTarget(id: "avd:" + avd, name: avd, kind: .emulator, serial: nil, avd: avd, state: "stopped"),
                                                         configuration: configuration, at: root, log: log)
                    }
                    let abi: String
                    if let serial { abi = try await tools.abi(serial: serial, configuration: configuration, at: root) }
                    else { abi = invocation.options["abi"] ?? "arm64-v8a" }
                    let output = URL(fileURLWithPath: invocation.options["output"] ?? root.appendingPathComponent("Exports/Android").path).standardizedFileURL
                    try validateOutput(output, project: root)
                    let lock = try EditorCLIBuildLock(at: root.appendingPathComponent(".ada/cli-build.lock"))
                    defer { lock.release() }
                    let scratch = invocation.options["scratch-path"].map { URL(fileURLWithPath: $0) }
                    let result = try await EditorAndroidProjectExporter(runner: runner).export(project: project, at: root, to: output, sdk: sdk,
                        configuration: configuration, abi: abi, product: invocation.options["product"], buildConfiguration: invocation.options["configuration"] ?? "debug", scratchDirectory: scratch, log: log)
                    let apk = try EditorAndroidProjectExporter.apk(in: result)
                    if let serial {
                        try await tools.launch(apk: apk, applicationID: EditorAndroidConfiguration.applicationID(for: project.project.name ?? root.lastPathComponent),
                                               serial: serial, configuration: configuration, at: root, requiresAOTReady: project.build.system.isAdaScript, log: log)
                        report.details["device"] = serial
                    }
                    report.artifacts = [apk.path]
                    report.details["exportDirectory"] = result.path
                    report.details["target"] = "android"
                    return report
                }
                guard project.build.system.isAdaScript else {
                    throw EditorCLIError.argument("CLI app packaging currently supports AdaScript projects. Build SwiftPM projects with swift build.")
                }
                #if canImport(GravityAOT)
                guard EditorDistribution.current.supportsSwiftProjects else {
                    throw EditorCLIError.environment("Native builds require the standalone macOS distribution of Ada Studio.")
                }
                let sdk = try EditorBuildSDK.locate(override: invocation.options["sdk"])
                let swift = await swiftExecutable(for: invocation)
                try await checkTools(swift: swift, runner: runner, at: root)
                let web = invocation.options["target"] == "web"
                let target = web ? "Web" : "macOS"
                let output = URL(fileURLWithPath: invocation.options["output"] ?? root.appendingPathComponent("Exports/\(target)").path).standardizedFileURL
                try validateOutput(output, project: root)
                let scratch = URL(fileURLWithPath: invocation.options["scratch-path"] ?? root.appendingPathComponent(".ada/cli-build/\(target)").path)
                let lock = try EditorCLIBuildLock(at: root.appendingPathComponent(".ada/cli-build.lock"))
                defer { lock.release() }
                let outputLock = try EditorCLIBuildLock(at: output.deletingLastPathComponent().appendingPathComponent(".\(output.lastPathComponent).ada-cli.lock"))
                defer { outputLock.release() }
                let scratchLock = try EditorCLIBuildLock(at: scratch.appendingPathComponent(".ada-cli.lock"))
                defer { scratchLock.release() }
                let options = EditorAdaScriptNativeExportOptions(
                    destination: web ? .web : .macOS,
                    gravityRoot: sdk.compilerRoot,
                    engineRoot: sdk.engineRoot,
                    swiftExecutable: swift,
                    swiftSDK: invocation.options["swift-sdk"] ?? ProcessInfo.processInfo.environment["ADA_WEB_SWIFT_SDK"] ?? "swift-6.3.2-RELEASE_wasm",
                    configuration: invocation.options["configuration"] == "debug" ? .debug : .release,
                    scratchDirectory: scratch,
                    hostScratchDirectory: web ? scratch.appendingPathComponent("host") : nil
                )
                let result: URL
                do {
                    result = try await EditorAdaScriptNativeExporter(runner: runner).export(project: project, at: root, to: output, options: options, log: log)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw EditorCLIError.build(error.localizedDescription)
                }
                report.artifacts = [result.appendingPathComponent(web ? "web/index.html" : "AdaNativeGame.app").path]
                report.details["exportDirectory"] = result.path
                report.details["target"] = web ? "web" : "macos"
                #else
                throw EditorCLIError.environment("This Studio build does not include the AdaScript AOT backend.")
                #endif
            }
            try Task.checkCancellation()
            return report
        } catch {
            return failure(command: invocation.command.rawValue, error: error, fallbackCode: 3)
        }
    }

    private static func preflightTypes(_ project: AdaProject, at root: URL) throws {
        // Keep compiler issue locations intact instead of converting them to the builder's UI text.
        let sourceRoot = project.paths.sources ?? "Sources"
        let sources = try EditorScriptableObjectCatalogLoader.load(project: project, at: root).playRuntime.sources.map { source in
            let relative = sourceRoot + "/" + source.path
            let path = FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path) ? relative : source.path
            return AdaScriptSource(path: path, source: source.source)
        }
        var environment = AdaScriptTypeEnvironment.standard
        environment.register(schemas: try AdaScriptSchemaParser.parse(sources: sources))
        try AdaScriptAnalyzer.analyze(sources: sources, environment: environment).requireValidTypes(mode: project.build.adaScriptTypeChecking)
    }

    private static func validateProjectPaths(_ project: AdaProject, at root: URL) throws {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let paths = [project.paths.sources ?? "Sources", project.paths.assets ?? "Assets", project.runtime.entry.scene].compactMap { $0 }
        for path in paths {
            let resolved = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(canonical) else {
                throw EditorCLIError.project("Project path resolves outside the project: \(path)")
            }
        }
    }

    private static func validateOutput(_ output: URL, project: URL) throws {
        let canonical = output.resolvingSymlinksInPath().standardizedFileURL
        let root = project.resolvingSymlinksInPath().standardizedFileURL
        guard canonical != root, !root.path.hasPrefix(canonical.path + "/"), canonical.lastPathComponent != ".ada" else {
            throw EditorCLIError.argument("Output must be a separate directory, not the project or its parent.")
        }
    }

    private static func swiftExecutable(for invocation: EditorCLIInvocation) async -> String {
        if let explicit = invocation.options["swift"] {
            return explicit
        }
        if invocation.options["target"] == "web", let web = ProcessInfo.processInfo.environment["ADA_WEB_SWIFT_EXECUTABLE"] {
            return web
        }
        return await SwiftToolchainLocator.locate().swiftExecutablePath
    }

    private static func checkTools(swift: String, runner: any EditorProcessRunning, at root: URL) async throws {
        for executable in [swift, "/usr/bin/clang", "/usr/bin/python3"] {
            try Task.checkCancellation()
            let result = await runner.run(EditorProcessCommand(executablePath: executable, arguments: ["--version"], workingDirectory: root))
            try Task.checkCancellation()
            guard result.succeeded else {
                throw EditorCLIError.environment("Required tool is unavailable: \(executable). \(result.combinedOutput)")
            }
        }
    }

    private static func failure(command: String, error: any Error, fallbackCode: Int32) -> EditorCLIReport {
        var report = EditorCLIReport(command: command, ok: false, exitCode: (error as? EditorCLIError)?.exitCode ?? fallbackCode)
        if error is CancellationError {
            report.exitCode = 130
            report.diagnostics = [.init(code: "cancelled", message: "Command cancelled.")]
        } else if let typeError = error as? AdaScriptTypeCheckingError {
            report.diagnostics = typeError.issues.map { issue in
                .init(
                    code: "adascript.\(issue.kind)",
                    message: issue.message,
                    file: issue.path,
                    line: issue.range.start.line + 1,
                    column: issue.range.start.utf16Column + 1
                )
            }
        } else {
            let codes: [Int32: String] = [2: "usage.invalid", 3: "project.invalid", 4: "environment.unavailable", 5: "build.failed"]
            report.diagnostics = [.init(code: codes[report.exitCode] ?? "command.failed", message: error.localizedDescription)]
        }
        return report
    }

    private static func emit(_ report: EditorCLIReport, format: EditorCLIInvocation.Format) {
        if format == .json {
            do { try FileHandle.standardOutput.write(contentsOf: report.encoded() + Data("\n".utf8)) } catch {
                try? FileHandle.standardError.write(contentsOf: Data("Unable to encode CLI result: \(error)\n".utf8))
            }
        } else {
            let text: String
            if let help = report.details["help"] {
                text = help
            } else {
                text = (["\(report.command): \(report.ok ? "succeeded" : "failed")"]
                    + report.details.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
                    + report.artifacts.map { "artifact: \($0)" }
                    + report.diagnostics.map { "\($0.code): \($0.message)" }).joined(separator: "\n")
            }
            try? (report.ok ? FileHandle.standardOutput : FileHandle.standardError).write(contentsOf: Data((text + "\n").utf8))
        }
    }
}
#endif
