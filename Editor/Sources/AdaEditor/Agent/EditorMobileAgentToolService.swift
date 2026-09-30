@_spi(Internal) import AdaEngine
import AdaScriptCompilerCore
import Foundation
import GravityLanguageCore
import MCP

/// Mobile tool execution remains on the UI actor; each instance belongs to one project turn.
@MainActor
final class EditorMobileAgentToolService {
    let projectURL: URL
    private let workspace = GravityWorkspace()
    private let liveDiagnostics: @MainActor () -> [String]
    private let startPlay: (@MainActor () throws -> Void)?
    private let capturePlay: (@MainActor () async throws -> Data)?
    private let assetTools: EditorAgentAssetToolService
    private let webTools: EditorAgentWebToolService
    private var runtime: EditorAgentSimulation?
    private var entries: [[String: Any]] = []
    private var cursor = 0

    init(
        projectURL: URL,
        liveDiagnostics: @escaping @MainActor () -> [String] = { [] },
        startPlay: (@MainActor () throws -> Void)? = nil,
        imageCredentials: any EditorImageCredentialProviding = EditorOpenAIImageCredentialStore(),
        imageClient: any EditorImageGenerationHTTPClient = EditorImageHTTPClient(),
        imageAnalyzer: (@MainActor ([URL], String) async throws -> String)? = nil,
        capturePlay: (@MainActor () async throws -> Data)? = nil,
        webClient: any EditorWebHTTPClient = EditorWebURLSessionClient()
    ) {
        self.projectURL = projectURL.resolvingSymlinksInPath().standardizedFileURL
        self.liveDiagnostics = liveDiagnostics
        self.startPlay = startPlay
        self.capturePlay = capturePlay
        self.assetTools = EditorAgentAssetToolService(projectURL: projectURL, credentials: imageCredentials, imageClient: imageClient, analyzeImage: imageAnalyzer)
        self.webTools = EditorAgentWebToolService(projectURL: projectURL, client: webClient)
        EditorComponentRegistry.registerBuiltIns()
    }

    func handle(name: String, arguments: [String: Value] = [:]) async -> EditorMobileAgentToolResult {
        do {
            let data = try await execute(name: name, arguments: arguments)
            let runtimeFailed = (name.hasPrefix("editor.runtime.") || name.hasPrefix("editor.play.")) && !(data["diagnostics"] as? [String] ?? []).isEmpty
            return result(ok: !runtimeFailed, data: data)
        } catch {
            let message = errorMessage(error)
            record(stage: name, message: message, ok: false)
            return result(ok: false, data: ["tool": name, "error": message])
        }
    }

    func build() -> EditorMobileAgentToolResult {
        do {
            let artifact = try buildArtifact()
            let summary = "AdaScript compilation and all project scenes succeeded: \(artifact.report.sourceCount) source(s), \(artifact.report.systemCount) system(s)."
            record(stage: "build", message: summary, ok: true)
            return result(ok: true, data: ["summary": summary, "verification": "compilation_and_scene_loading", "gameplayVerified": false])
        } catch {
            let message = errorMessage(error)
            record(stage: "build", message: message, ok: false)
            // Preserve the compiler/loader's complete error and supplement it with navigable LSP positions.
            return result(
                ok: false,
                data: [
                    "stage": "build", "error": message,
                    "diagnostics": (try? diagnostics(path: nil)) ?? [:],
                ]
            )
        }
    }

    func finish() {
        runtime?.stop()
        runtime = nil
    }

    /// Completion gate: scene loading plus actual startup/update callbacks, with no rendering claim.
    func validatePrototype() async -> EditorMobileAgentToolResult {
        let buildResult = build()
        guard buildResult.ok else {
            return buildResult
        }
        do {
            let simulation = try EditorAgentSimulation(artifact: buildArtifact())
            defer { simulation.stop() }
            try await simulation.start()
            try await simulation.step(frames: 8, deltaTime: 1.0 / 60, keys: [])
            let snapshot = simulation.snapshot()
            let ok = simulation.diagnostics.isEmpty
            record(stage: "completion", message: ok ? "Build, all scenes and 8 simulation frames succeeded." : simulation.diagnostics.joined(separator: "\n"), ok: ok)
            return result(ok: ok, data: snapshot)
        } catch {
            let message = errorMessage(error)
            record(stage: "completion", message: message, ok: false)
            return result(ok: false, data: ["stage": "simulation", "error": message])
        }
    }

    func buildArtifact() throws -> EditorAdaScriptProjectBuildArtifact {
        let project = try ProjectSystem.validateProjectLayout(at: projectURL)
        try ProjectSystem.validateRunCompatibility(of: project, at: projectURL, destination: .iPadOS)
        _ = try resolve(project.paths.sources ?? "Sources")
        _ = try resolve(project.paths.assets ?? "Assets")
        if let path = project.runtime.entry.scene { _ = try resolve(path) }
        let artifact = try EditorAdaScriptProjectBuilder().prepare(project: project, at: projectURL)
        try validateScenes(artifact: artifact)
        return artifact
    }

    private func execute(name: String, arguments: [String: Value]) async throws -> [String: Any] {
        switch name {
        case "editor.project.context":
            let project = try ProjectSystem.loadProject(at: projectURL)
            return [
                "project": try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)),
                "tools": EditorMobileAgentTools.tools().map(\.name),
                "languageService": "embedded GravityWorkspace; current disk sources; zero-based UTF-16 positions",
                "simulation": "AdaScript, scenes, keyboard input, transforms and physics; rendering, audio, networking and touch UI require visible Play",
                "limitations": ["AdaScript @view and @resource declarations are currently unavailable in portable projects; use supported scene UI components and @res Input."],
            ]
        case "editor.gravity.diagnostics":
            return try diagnostics(path: arguments["path"]?.stringValue)
        case "editor.gravity.completion", "editor.gravity.hover", "editor.gravity.definition":
            return try languageQuery(name: name, arguments: arguments)
        case "editor.docs.search", "editor.docs.read", "editor.api.describe", "editor.components.describe", "editor.examples.list", "editor.examples.read":
            return try EditorAgentKnowledge.query(name: name, arguments: arguments)
        case "editor.project.configure":
            return try configure(settings: requiredString("settingsJSON", arguments))
        case "editor.scene.validate":
            let artifact = try buildArtifact()
            let paths = try validateScenes(artifact: artifact, path: arguments["path"]?.stringValue)
            return ["scenes": paths, "summary": "All requested scenes loaded without warnings."]
        case "editor.runtime.start":
            let artifact = try buildArtifact()
            finish()
            let candidate = try EditorAgentSimulation(artifact: artifact)
            do { try await candidate.start() } catch {
                candidate.stop()
                throw error
            }
            runtime = candidate
            record(stage: "runtime", message: "Isolated simulation started", ok: candidate.diagnostics.isEmpty)
            return candidate.snapshot()
        case "editor.runtime.step":
            guard let runtime else { throw ToolError("Call editor.runtime.start first.") }
            let frames = try integer("frames", arguments, default: 1)
            let delta = arguments["deltaTime"]?.doubleValue ?? 1.0 / 60
            guard (1...120).contains(frames), delta.isFinite, delta > 0, delta <= 0.1 else { throw ToolError("frames must be 1...120 and deltaTime in (0, 0.1].") }
            let keys: [String]?
            if let value = arguments["keys"], value != .null {
                guard let array = value.arrayValue, array.allSatisfy({ $0.stringValue != nil }) else { throw ToolError("keys must be an array of key names.") }
                keys = array.compactMap(\.stringValue)
            } else {
                keys = nil
            }
            try await runtime.step(frames: frames, deltaTime: delta, keys: keys)
            for message in runtime.diagnostics { record(stage: "runtime", message: message, ok: false) }
            return runtime.snapshot()
        case "editor.runtime.inspect":
            guard let runtime else { throw ToolError("Call editor.runtime.start first.") }
            return runtime.snapshot()
        case "editor.runtime.stop":
            finish()
            return ["stopped": true]
        case "editor.play.start":
            guard let startPlay else { throw ToolError("Visible Play is unavailable in this host. Use editor.runtime.start for simulation.") }
            try startPlay()
            return ["presented": true, "diagnostics": liveDiagnostics(), "interactionVerified": false]
        case "editor.play.inspect":
            return ["diagnostics": liveDiagnostics(), "interactionVerified": false]
        case "editor.play.capture":
            guard let capturePlay else { throw ToolError("Visible Play capture is unavailable in this host.") }
            let data = try await capturePlay()
            return try assetTools.saveCapturedFrame(data)
        case "editor.output.read":
            let after = max(0, try integer("after", arguments, default: 0))
            return [
                "entries": entries.filter { ($0["cursor"] as? Int ?? 0) > after }, "nextCursor": cursor,
                "dropped": max(0, (entries.first?["cursor"] as? Int ?? 1) - after - 1),
                "playDiagnostics": liveDiagnostics(), "simulationDiagnostics": runtime?.diagnostics ?? [],
            ]
        default:
            if EditorAgentWebTools.contains(name) {
                return try await webTools.execute(name: name, arguments: arguments)
            }
            guard EditorAgentAssetTools.tools().contains(where: { $0.name == name }) else { throw ToolError("Unknown mobile editor tool: \(name)") }
            return try await assetTools.execute(name: name, arguments: arguments)
        }
    }

    private func refreshWorkspace() {
        workspace.configure(rootURIs: [projectURL.absoluteString])
        workspace.setHostConstructors(
            RuntimeTypeRegistry.registeredRuntimeComponentConstructors().map {
                GravityHostConstructor(name: $0.name, parameters: $0.parameters.map(\.name))
            }
        )
    }

    private func diagnostics(path: String?) throws -> [String: Any] {
        refreshWorkspace()
        let project = try ProjectSystem.loadProject(at: projectURL)
        let files =
            try path.map { [try resolve($0, extensions: ["ada", "gravity"])] }
            ?? projectFiles(under: project.paths.sources ?? "Sources", extensions: ["ada", "gravity"])
        var values: [[String: Any]] = []
        for url in files {
            let text = try read(url)
            workspace.change(uri: url.absoluteString, text: text, version: nil)
        }
        for url in files {
            let items = workspace.analysis(for: url.absoluteString)?.diagnostics ?? []
            values.append(
                contentsOf: items.map {
                    [
                        "path": relativePath(url), "severity": $0.severity == .error ? "error" : "warning", "message": $0.message,
                        "source": "adascript-lsp", "range": range($0.range),
                    ]
                }
            )
        }
        return ["files": files.map(relativePath), "diagnostics": values, "coordinates": "zero-based UTF-16"]
    }

    private func languageQuery(name: String, arguments: [String: Value]) throws -> [String: Any] {
        let url = try resolve(requiredString("path", arguments), extensions: ["ada", "gravity"])
        let text = try read(url)
        let line = try integer("line", arguments)
        let column = try integer("character", arguments)
        guard line >= 0, column >= 0
        else { throw ToolError("Provide nonnegative integer line and character.") }
        let lines = text.components(separatedBy: .newlines)
        guard lines.indices.contains(line), column <= lines[line].utf16.count else { throw ToolError("Position is outside the source file.") }
        refreshWorkspace()
        workspace.change(uri: url.absoluteString, text: text, version: nil)
        let position = GravitySourcePosition(line: line, utf16Column: column)
        switch name {
        case "editor.gravity.completion":
            let items = workspace.completions(uri: url.absoluteString, position: position)
            return [
                "items": items.prefix(100).map {
                    ["label": $0.label, "detail": $0.detail, "insertText": $0.insertText, "replacementRange": range($0.replacementRange)] as [String: Any]
                },
                "truncated": items.count > 100,
            ]
        case "editor.gravity.hover":
            guard let hover = workspace.hover(uri: url.absoluteString, position: position) else {
                return ["contents": NSNull()]
            }
            return ["contents": hover.contents, "range": range(hover.range)]
        default:
            guard let target = workspace.definition(uri: url.absoluteString, position: position) else {
                return ["targets": []]
            }
            let targetURL = URL(string: target.uri)
            return ["targets": [["path": targetURL.map(relativePath) ?? target.uri, "range": range(target.range), "selectionRange": range(target.selectionRange)]]]
        }
    }

    @discardableResult
    private func validateScenes(artifact: EditorAdaScriptProjectBuildArtifact, path: String? = nil) throws -> [String] {
        try artifact.scenePlayRuntime.registerScriptableObjects()
        let files =
            try path.map { [try resolve($0, extensions: ["ascn"])] }
            ?? projectFiles(under: relativePath(artifact.assetsDirectory), extensions: ["ascn"])
        for url in files {
            let model = try EditorSceneModel.decode(from: read(url))
            let result = EditorSceneFileLoader.load(
                model: model,
                into: World(name: "Mobile agent scene validation"),
                sourceURL: url,
                resourceRootURL: artifact.assetsDirectory
            )
            guard result.warnings.isEmpty else {
                throw EditorAdaScriptProjectBuildError.startupSceneInvalid(path: relativePath(url), message: result.warnings.joined(separator: "\n"))
            }
        }
        try MobileEditorSceneValidation.validate(artifact, at: projectURL)
        return files.map(relativePath)
    }

    private func configure(settings: String) throws -> [String: Any] {
        guard let patch = try JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any],
            !patch.isEmpty, Set(patch.keys).isSubset(of: ["runtime", "inputActions", "ai"])
        else {
            throw ToolError("Only runtime.entry, runtime.plugins, inputActions and ai.imageGeneration can be configured.")
        }
        let original = try ProjectSystem.loadProject(at: projectURL)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any] ?? [:]
        if let runtimePatch = patch["runtime"] {
            guard let fields = runtimePatch as? [String: Any], Set(fields.keys).isSubset(of: ["entry", "plugins"]) else {
                throw ToolError("runtime accepts only entry and plugins.")
            }
            var current = object["runtime"] as? [String: Any] ?? [:]
            for (key, value) in fields { current[key] = value }
            object["runtime"] = current
        }
        if let actions = patch["inputActions"] { object["inputActions"] = actions }
        if let ai = patch["ai"] {
            guard let values = ai as? [String: Any], Set(values.keys) == ["imageGeneration"] else { throw ToolError("ai accepts only imageGeneration.") }
            var current = object["ai"] as? [String: Any] ?? [:]
            current["imageGeneration"] = values["imageGeneration"]
            object["ai"] = current
        }
        let candidate = try ProjectSystem.loadProject(from: JSONSerialization.data(withJSONObject: object))
        try ProjectSystem.validate(candidate)
        try InputAction.validate(candidate.inputActions)
        _ = try EditorAdaScriptRuntimePluginResolver.resolve(candidate.runtime.plugins)
        if let path = candidate.runtime.entry.scene { _ = try resolve(path, extensions: ["ascn"]) }
        guard candidate.runtime.entry.view == nil else { throw EditorAdaScriptProjectBuildError.uiViewsUnavailable }
        try ProjectSystem.saveProject(candidate, at: projectURL)
        finish()
        return ["project": object, "requiresRebuild": true]
    }

    func resolve(_ path: String, extensions: Set<String>? = nil) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.split(separator: "/").contains("..") else {
            throw ToolError("Use a project-relative path without traversal: \(path)")
        }
        let url = projectURL.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathComponents.starts(with: projectURL.pathComponents), url.pathComponents.count > projectURL.pathComponents.count,
            extensions?.contains(url.pathExtension.lowercased()) ?? true
        else {
            throw ToolError("Path is outside the project or has an unsupported extension: \(path)")
        }
        return url
    }

    private func projectFiles(under path: String, extensions: Set<String>) throws -> [URL] {
        let root = try resolve(path)
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw ToolError("Cannot enumerate project directory: \(path)")
        }
        var result: [URL] = []
        for case let file as URL in iterator where extensions.contains(file.pathExtension.lowercased()) {
            result.append(try resolve(relativePath(file), extensions: extensions))
            guard result.count <= 500 else { throw ToolError("Project exceeds the 500-file validation limit.") }
        }
        return result.sorted { $0.path < $1.path }
    }

    private func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard data.count <= 256 * 1024, let text = String(data: data, encoding: .utf8) else { throw ToolError("Expected a UTF-8 source file up to 256 KB.") }
        return text
    }

    private func relativePath(_ url: URL) -> String {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let components = resolved.pathComponents
        let root = projectURL.pathComponents
        return components.starts(with: root) ? components.dropFirst(root.count).joined(separator: "/") : resolved.path
    }

    private func range(_ value: GravitySourceRange) -> [String: Any] {
        ["start": ["line": value.start.line, "character": value.start.utf16Column], "end": ["line": value.end.line, "character": value.end.utf16Column]]
    }

    private func requiredString(_ key: String, _ arguments: [String: Value]) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else { throw ToolError("Missing \(key).") }
        return value
    }

    private func integer(_ key: String, _ arguments: [String: Value], default defaultValue: Int? = nil) throws -> Int {
        guard let value = arguments[key], value != .null else {
            if let defaultValue {
                return defaultValue
            }
            throw ToolError("Missing integer \(key).")
        }
        switch value {
        case let .int(number): return number
        case let .double(number):
            if let integer = Int(exactly: number) {
                return integer
            }
        default: break
        }
        throw ToolError("\(key) must be a representable integer.")
    }

    private func record(stage: String, message: String, ok: Bool) {
        cursor += 1
        entries.append(["cursor": cursor, "stage": stage, "message": message, "ok": ok])
        if entries.count > 100 { entries.removeFirst(entries.count - 100) }
    }

    private func result(ok: Bool, data: [String: Any]) -> EditorMobileAgentToolResult {
        var object = data
        object["ok"] = ok
        do {
            let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return EditorMobileAgentToolResult(ok: ok, payload: try EditorAgentToolEncoding.string(encoded))
        } catch {
            return EditorMobileAgentToolResult(ok: false, payload: "Tool result serialization failed: \(error.localizedDescription)")
        }
    }

    private func errorMessage(_ error: any Error) -> String {
        if let message = (error as? any LocalizedError)?.errorDescription {
            return message
        }
        return String(describing: error)
    }

    private struct ToolError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
