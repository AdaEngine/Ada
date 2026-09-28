import Foundation
import MCP

@MainActor
final class EditorAgentWorkspaceMCPTools {
    static let shared = EditorAgentWorkspaceMCPTools()

    private init() {}

    static func tools() -> [Tool] {
        [
            Tool(
                name: "editor.build.start",
                description: "Build the open project using Ada Editor's native build workflow. Poll editor.task.status and read editor.output.read for results.",
                inputSchema: objectSchema(),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "editor.test.start",
                description: "Run project tests using Ada Editor's native test workflow. Poll editor.task.status and read editor.output.read for results.",
                inputSchema: objectSchema(properties: ["filter": .object(["type": "string", "description": "Optional test name or filter."])]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "editor.play.start",
                description: "Run the active scene in the editor, or the selected project target when mode is 'product'.",
                inputSchema: objectSchema(properties: ["mode": .object(["type": "string", "enum": .array(["scene", "product"].map(Value.string)), "description": "Defaults to scene when a scene document is active; otherwise product."])]),
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
           project.build.system.isAdaScript {
            throw EditorWorkspaceMCPError.testsUnavailableForAdaScript
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

    private func stopTask() throws -> String {
        let viewModel = try requireViewModel()
        guard
            viewModel.workspaceTask != nil
                || viewModel.playModeState.isPlaying
                || viewModel.debugger.isActive
                || viewModel.playerSession.isRunning
                || viewModel.playerSession.isBusy
        else {
            throw EditorWorkspaceMCPError.noTaskToStop
        }
        viewModel.cancelWorkspaceCommand()
        return try json(["accepted": true, "status": viewModel.workspaceStatus.title, "playMode": String(describing: viewModel.playModeState)])
    }

    private func taskStatus() throws -> String {
        let viewModel = try requireViewModel()
        return try json([
            "status": viewModel.workspaceStatus.title,
            "isWorkspaceTaskRunning": viewModel.workspaceTask != nil,
            "playMode": String(describing: viewModel.playModeState),
            "activeDocument": viewModel.workbench.activeDocument.map { $0.relativePath } ?? "",
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
    case testsUnavailableForAdaScript
    case noActiveScene
    case invalidPlayMode(String)
    case invalidOutputSource(String)
    case outputCursorExpired

    var errorDescription: String? {
        switch self {
        case .noOpenProject: "Open an Ada project in Ada Editor first."
        case .taskAlreadyRunning: "An editor task is already running. Read editor.task.status or stop it before starting another."
        case .noTaskToStop: "There is no active editor task or play session to stop."
        case .documentSaveFailed: "Could not save all dirty documents; fix the save conflict before starting the editor task."
        case .testsUnavailableForAdaScript: "The project uses AdaScript and does not have SwiftPM tests."
        case .noActiveScene: "Open a scene document before starting scene Play Mode."
        case let .invalidPlayMode(mode): "Unsupported play mode: \(mode). Use 'scene' or 'product'."
        case let .invalidOutputSource(source): "Unknown output source '\(source)'. Use 'editor' or 'game'."
        case .outputCursorExpired: "The output cursor expired when the bounded log buffer rolled over. Read the latest output without afterID."
        }
    }
}
