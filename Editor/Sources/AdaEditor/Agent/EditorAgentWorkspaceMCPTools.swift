import Foundation
import MCP

@MainActor
final class EditorAgentWorkspaceMCPTools {
    static let shared = EditorAgentWorkspaceMCPTools()

    private var scenarioIsRunning = false

    private init() {}

    static func tools() -> [Tool] {
        [
            Tool(
                name: "editor.build.start",
                description: "Build the open project using Ada Editor's native build workflow. Poll editor.task.status and read editor.output.read for results.",
                inputSchema: objectSchema(),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false),
                // Lets harnesses such as Sloppy count a successful call as completion evidence.
                _meta: Metadata(additionalFields: ["sloppy/verification": "build"])
            ),
            Tool(
                name: "editor.test.start",
                description: "Run project tests. SwiftPM projects run `swift test`. AdaScript projects (build.system adascript) run every @test function found in any .ada file or under Tests/ in-process, no SwiftPM, each with a 30 s timeout; it is rejected when the project has no @test. Poll editor.task.status (status plus adaScriptTests passed/failed/total and per-test results) and read editor.output.read: one PASS/FAIL line per test, failures followed by `path:line:column: message`.",
                inputSchema: objectSchema(properties: ["filter": .object(["type": "string", "description": "Optional text; only tests whose function name or @test display name contains it run."])]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false),
                // Lets harnesses such as Sloppy count a successful call as completion evidence.
                _meta: Metadata(additionalFields: ["sloppy/verification": "test"])
            ),
            Tool(
                name: "editor.play.start",
                description: "Run the active scene in the editor, or the selected project target when mode is 'product'.",
                inputSchema: objectSchema(properties: ["mode": .object(["type": "string", "enum": .array(["scene", "product"].map(Value.string)), "description": "Defaults to scene when a scene document is active; otherwise product."])]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false),
                // Lets harnesses such as Sloppy count a successful call as completion evidence.
                _meta: Metadata(additionalFields: ["sloppy/verification": "run"])
            ),
            Tool(
                name: "editor.play.capture",
                description: "Capture the next completed frame of the RUNNING GAME (2D or 3D game camera, never the editor window) as a PNG under .ada/workspace/agent-captures. Start Play first; errors explicitly when no game is running. Read the returned path as an image.",
                inputSchema: objectSchema(properties: [
                    "cameraName": .object(["type": "string", "description": "Require this camera to be active in the game."]),
                    "maxDimension": .object(["type": "integer", "minimum": 64, "maximum": EditorPlayScenario.Limits.maxDimension.asValue, "description": .string("Downscale so neither side exceeds this. Default \(EditorPlayScenario.Limits.defaultDimension).")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "editor.play.run_scenario",
                description: """
                    Verify a game without a human. Runs the AdaScript project in an isolated offscreen runtime (target 'offscreen', default) or attaches to the running Play game (target 'play'), \
                    replays timed input, captures game-camera frames (PNG) and reads game state at chosen moments, then returns frames, snapshots, script logs/errors and a verdict-ready summary. \
                    steps: [{t:0.5,key:'space',tap:true},{t:1,capture:'after-flap'},{t:1.2,snapshot:'state'},{t:2,key:'r',down:true},{t:2.1,key:'r',down:false},{t:3,mouse:'left',tap:true,x:100,y:80},{t:3,move:{x:10,y:20}}]. \
                    Key names: space, r, w, arrowUp, enter, escape... Limits: \(Int(EditorPlayScenario.Limits.maxDuration))s, \(EditorPlayScenario.Limits.maxEvents) events, \(EditorPlayScenario.Limits.maxFrames) frames, \(EditorPlayScenario.Limits.maxSnapshots) snapshots. \
                    Timing is wall-clock; state snapshots read entity components, so expose values you need (for example @export fields or System.print lines).
                    """,
                inputSchema: objectSchema(properties: [
                    "steps": .object(["type": "array", "items": .object(["type": "object"]), "description": "Timed events; see tool description."]),
                    "duration": .object(["type": "number", "description": "Total seconds; defaults to last event + 0.5."]),
                    "target": .object(["type": "string", "enum": .array(["offscreen", "play"].map(Value.string))]),
                    "warmup": .object(["type": "boolean", "description": "Default true: the clock starts after the game rendered its first frames. Use false to capture startup frames (flash/blank-frame checks)."]),
                    "watch": .object(["type": "object", "description": "{entities:[names], components:[type names]} to include in snapshots; default is the first 25 entities."]),
                    "maxDimension": .object(["type": "integer", "description": .string("Longest frame side in pixels. Default \(EditorPlayScenario.Limits.defaultDimension).")]),
                    "width": .object(["type": "integer", "description": .string("Offscreen surface width. Default \(EditorPlayScenario.Limits.defaultSize.width).")]),
                    "height": .object(["type": "integer", "description": .string("Offscreen surface height. Default \(EditorPlayScenario.Limits.defaultSize.height).")])
                ], required: ["steps"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "editor.task.stop",
                description: "Stop the active build, test, run, debugger, player, or editor Play Mode session.",
                inputSchema: objectSchema(),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "editor.task.status",
                description: "Read the current editor build, test, run, and Play Mode status.",
                inputSchema: objectSchema(),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "editor.output.read",
                description: "Read editor build/test output or game logs with a cursor. Continue with nextCursor; cursors expire when the bounded output buffer rolls over.",
                inputSchema: objectSchema(properties: [
                    "source": .object(["type": "string", "enum": .array(["editor", "game"].map(Value.string)), "description": "Choose editor command output or game runtime logs."]),
                    "afterID": .object(["type": "string", "description": "Return lines after this previous line ID."]),
                    "limit": .object(["type": "integer", "description": "Maximum lines to return; defaults to 100 and is capped at 200."])
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            )
        ]
    }

    func handle(name: String, arguments: [String: Value]) -> CallTool.Result? {
        do {
            let payload: String
            switch name {
            case "editor.build.start": payload = try startBuild()
            case "editor.test.start": payload = try startTests(filter: arguments["filter"]?.stringValue)
            case "editor.play.start": payload = try startPlay(mode: arguments["mode"]?.stringValue)
            case "editor.task.stop": payload = try stopTask()
            case "editor.task.status": payload = try taskStatus()
            case "editor.output.read": payload = try readOutput(
                source: arguments["source"]?.stringValue,
                afterID: arguments["afterID"]?.stringValue,
                limit: arguments["limit"]?.intValue
            )
            default: return nil
            }
            return .init(content: [.text(text: payload, annotations: nil, _meta: nil)], isError: false)
        } catch {
            return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
        }
    }

    func handleAsync(name: String, arguments: [String: Value]) async -> CallTool.Result? {
        guard name == "editor.play.capture" || name == "editor.play.run_scenario" else { return nil }
        do {
            let payload: String
            if name == "editor.play.capture" {
                let viewModel = try requireViewModel()
                guard let projectURL = viewModel.projectURL else { throw EditorWorkspaceMCPError.noOpenProject }
                payload = try json(try await EditorGameFrameCapture.captureTool(
                    projectURL: projectURL,
                    cameraName: arguments["cameraName"]?.stringValue,
                    maxDimension: arguments["maxDimension"]?.intValue
                ))
            } else {
                payload = try json(try await runScenario(arguments))
            }
            return .init(content: [.text(text: payload, annotations: nil, _meta: nil)], isError: false)
        } catch {
            return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
        }
    }

    private func runScenario(_ arguments: [String: Value]) async throws -> [String: Any] {
        guard !scenarioIsRunning else { throw EditorWorkspaceMCPError.scenarioAlreadyRunning }
        let scenario = try EditorPlayScenario.parse(arguments)
        let viewModel = try requireViewModel()
        guard let projectURL = viewModel.projectURL else { throw EditorWorkspaceMCPError.noOpenProject }
        scenarioIsRunning = true
        defer { scenarioIsRunning = false }

        let host: EditorSceneViewScenarioHost
        switch scenario.target {
        case .play:
            host = try EditorSceneViewScenarioHost.attachToPlay()
        case .offscreen:
            try saveDocumentsBeforeTask(viewModel)
            let project = try ProjectSystem.loadProject(at: projectURL, fileManager: viewModel.fileManager)
            guard project.build.system.isAdaScript else { throw EditorWorkspaceMCPError.scenarioNeedsAdaScript }
            let destination = viewModel.selectedRunDestination.adaProjectDestination
            let artifact = try await Task.detached(priority: .userInitiated) {
                try Self.prepareArtifact(project, at: projectURL, destination: destination)
            }.value
            host = try await EditorSceneViewScenarioHost.startOffscreen(artifact: artifact, size: scenario.surface, warmUp: scenario.warmUp)
        }
        defer { host.stop() }
        let directory = EditorGameFrameCapture.capturesDirectory(projectURL: projectURL)
        let runner = EditorPlayScenarioRunner(host: host) { image, label in
            try EditorGameFrameCapture.write(image, to: directory, name: "scenario-\(label)").path
        }
        return await runner.run(scenario)
    }

    nonisolated private static func prepareArtifact(
        _ project: AdaProject,
        at projectURL: URL,
        destination: AdaProjectRunDestination
    ) throws -> EditorAdaScriptProjectBuildArtifact {
        let fileManager = FileManager()
        try ProjectSystem.validateRunCompatibility(of: project, at: projectURL, destination: destination, fileManager: fileManager)
        return try EditorAdaScriptProjectBuilder(fileManager: fileManager).prepare(project: project, at: projectURL)
    }

    private func startBuild() throws -> String {
        let viewModel = try requireViewModel()
        guard viewModel.workspaceTask == nil else { throw EditorWorkspaceMCPError.taskAlreadyRunning }
        try saveDocumentsBeforeTask(viewModel)
        viewModel.buildAll()
        return try json(["accepted": true, "status": viewModel.workspaceStatus.title])
    }

    private func startTests(filter: String?) throws -> String {
        let viewModel = try requireViewModel()
        guard viewModel.workspaceTask == nil else { throw EditorWorkspaceMCPError.taskAlreadyRunning }
        if let projectURL = viewModel.projectURL,
           let project = try? ProjectSystem.loadProject(at: projectURL, fileManager: viewModel.fileManager),
           project.build.system.isAdaScript,
           !EditorAdaScriptTestRunner(fileManager: viewModel.fileManager).hasTests(project: project, at: projectURL) {
            throw EditorWorkspaceMCPError.noAdaScriptTests
        }
        try saveDocumentsBeforeTask(viewModel)
        viewModel.runTests(filter: filter)
        let filterValue: Any = filter.map { $0 as Any } ?? NSNull()
        return try json(["accepted": true, "status": viewModel.workspaceStatus.title, "filter": filterValue])
    }

    private func startPlay(mode: String?) throws -> String {
        let viewModel = try requireViewModel()
        guard viewModel.workspaceTask == nil else { throw EditorWorkspaceMCPError.taskAlreadyRunning }
        try saveDocumentsBeforeTask(viewModel)
        let selectedMode = mode ?? (viewModel.workbench.activeSceneDocument == nil ? "product" : "scene")
        switch selectedMode {
        case "scene":
            guard viewModel.workbench.activeSceneDocument != nil else { throw EditorWorkspaceMCPError.noActiveScene }
            viewModel.runActiveSceneInEditor()
        case "product":
            viewModel.runSelectedTarget()
        default:
            throw EditorWorkspaceMCPError.invalidPlayMode(selectedMode)
        }
        return try json(["accepted": true, "status": viewModel.workspaceStatus.title, "playMode": String(describing: viewModel.playModeState)])
    }

    #if os(Windows)
    func startTrackedPlay(document: EditorSceneDocument, entityID: String, editor: EditorViewModel) throws -> EditorTrackedScenePlay {
        guard editor.workspaceTask == nil else {
            throw EditorBlenderSceneJob.Failure.playBusy
        }
        if editor.playModeState.isPlaying {
            if let run = editor.trackedScenePlay, run.matches(document), run.entityID == entityID {
                editor.selectWorkbenchDocument(id: document.id)
                if editor.interface.mode == .agent { editor.interface.showsArtifact = true }
                return run
            }
            throw EditorBlenderSceneJob.Failure.playBusy
        }
        if document.isDirty, !editor.workbench.saveSceneDocument(id: document.id) {
            throw EditorWorkspaceMCPError.documentSaveFailed
        }
        editor.selectWorkbenchDocument(id: document.id)
        guard let saved = editor.workbench.activeSceneDocument, saved.id == document.id else {
            throw EditorBlenderSceneJob.Failure.playChanged
        }
        let run = EditorTrackedScenePlay(id: UUID(), sceneDocumentID: document.id, entityID: entityID,
                                        sceneRevision: EditorAgentSceneToolService.revision(for: saved.content))
        editor.runActiveSceneInEditor(tracking: run)
        guard editor.trackedScenePlay == run, editor.playModeState.isPlaying else { throw EditorBlenderSceneJob.Failure.playChanged }
        if editor.interface.mode == .agent { editor.interface.showsArtifact = true }
        return run
    }
    #endif

    private func stopTask() throws -> String {
        let viewModel = try requireViewModel()
        guard
            viewModel.workspaceTask != nil
                || viewModel.playModeState.isPlaying
                || viewModel.debugger.isActive
                || viewModel.isAdaPlayerActive
        else {
            throw EditorWorkspaceMCPError.noTaskToStop
        }
        viewModel.cancelWorkspaceCommand()
        return try json(["accepted": true, "status": viewModel.workspaceStatus.title, "playMode": String(describing: viewModel.playModeState)])
    }

    private static func testSummaryPayload(_ summary: EditorAdaScriptTestSummary?) -> [String: Any] {
        guard let summary else { return [:] }
        return [
            "finished": summary.finished,
            "passed": summary.passed,
            "failed": summary.failed,
            "total": summary.total,
            "failures": summary.outcomes.filter { !$0.passed }.map {
                ["name": $0.name, "location": "\($0.path):\($0.line)", "messages": $0.diagnostics] as [String: Any]
            }
        ]
    }

    private func taskStatus() throws -> String {
        let viewModel = try requireViewModel()
        return try json([
            "status": viewModel.workspaceStatus.title,
            "isWorkspaceTaskRunning": viewModel.workspaceTask != nil,
            "playMode": String(describing: viewModel.playModeState),
            "activeDocument": viewModel.workbench.activeDocument.map { $0.relativePath } ?? "",
            "adaScriptTests": Self.testSummaryPayload(viewModel.adaScriptTestSummary),
            "buildStep": viewModel.buildActivity?.currentStep.map { ["title": $0.title, "detail": $0.detail ?? ""] } ?? [:]
        ])
    }

    private func readOutput(source: String?, afterID: String?, limit: Int?) throws -> String {
        let viewModel = try requireViewModel()
        let selectedSource = source ?? "editor"
        if selectedSource == "game" {
            viewModel.collectRuntimeLogs()
        }
        let lines: [EditorWorkspaceLogLine]
        switch selectedSource {
        case "editor": lines = viewModel.outputLines
        case "game": lines = viewModel.gameLogLines
        default: throw EditorWorkspaceMCPError.invalidOutputSource(selectedSource)
        }

        let startIndex: Int
        if let afterID {
            guard let index = lines.firstIndex(where: { $0.id == afterID }) else {
                throw EditorWorkspaceMCPError.outputCursorExpired
            }
            startIndex = index + 1
        } else {
            startIndex = max(0, lines.count - min(max(limit ?? 100, 1), 200))
        }
        let maximum = min(max(limit ?? 100, 1), 200)
        let page = Array(lines.dropFirst(startIndex).prefix(maximum))
        let nextCursor = page.last?.id ?? afterID ?? ""
        return try json([
            "source": selectedSource,
            "lines": page.map { ["id": $0.id, "text": $0.text] },
            "nextCursor": nextCursor,
            "hasMore": startIndex + page.count < lines.count
        ])
    }

    private func requireViewModel() throws -> EditorViewModel {
        guard let viewModel = EditorAgentMCPTools.shared.activeViewModel, viewModel.project != nil else {
            throw EditorWorkspaceMCPError.noOpenProject
        }
        return viewModel
    }

    private func saveDocumentsBeforeTask(_ viewModel: EditorViewModel) throws {
        guard viewModel.workbench.saveAllDocuments() else {
            throw EditorWorkspaceMCPError.documentSaveFailed
        }
    }

    private static func objectSchema(properties: [String: Value] = [:], required: [String] = []) -> Value {
        var schema: [String: Value] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map(Value.string)) }
        return .object(schema)
    }

    private func json(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

private enum EditorWorkspaceMCPError: Error, LocalizedError {
    case noOpenProject
    case taskAlreadyRunning
    case noTaskToStop
    case documentSaveFailed
    case noAdaScriptTests
    case noActiveScene
    case invalidPlayMode(String)
    case invalidOutputSource(String)
    case outputCursorExpired
    case scenarioAlreadyRunning
    case scenarioNeedsAdaScript

    var errorDescription: String? {
        switch self {
        case .noOpenProject: "Open an Ada project in Ada Editor first."
        case .taskAlreadyRunning: "An editor task is already running. Read editor.task.status or stop it before starting another."
        case .noTaskToStop: "There is no active editor task or play session to stop."
        case .documentSaveFailed: "Could not save all dirty documents; fix the save conflict before starting the editor task."
        case .noAdaScriptTests: EditorAdaScriptTestError.noTests(filter: nil).errorDescription
        case .noActiveScene: "Open a scene document before starting scene Play Mode."
        case let .invalidPlayMode(mode): "Unsupported play mode: \(mode). Use 'scene' or 'product'."
        case let .invalidOutputSource(source): "Unknown output source '\(source)'. Use 'editor' or 'game'."
        case .scenarioAlreadyRunning: "Another editor.play.run_scenario is still running."
        case .scenarioNeedsAdaScript: "editor.play.run_scenario with target 'offscreen' supports AdaScript projects. For other projects use target 'play' after editor.play.start, or editor.play.capture."
        case .outputCursorExpired: "The output cursor expired when the bounded log buffer rolled over. Read the latest output without afterID."
        }
    }
}

private extension Int {
    var asValue: Value { .int(self) }
}
