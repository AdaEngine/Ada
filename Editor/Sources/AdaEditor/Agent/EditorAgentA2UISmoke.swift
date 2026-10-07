#if DEBUG && os(macOS)
import AdaA2UI
@_spi(AdaEngine) import AdaEngine
import AdaInput
import AdaUIDescription
import Foundation

/// Opt-in native QA; uses an isolated settings store and the production ACP service/workbench.
@MainActor
enum EditorAgentA2UISmoke {
    static var enabled: Bool { CommandLine.arguments.contains("--agent-a2ui-smoke") }

    static func prepareProjectIfNeeded() throws {
        guard enabled, let path = projectPath else {
            return
        }
        let root = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent(".ada/project.json").path) {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
            try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "A2UIWorkflow", buildSystem: .adaScript), at: root)
            let source = """
            @system(scheduler: "update", id: "game.main")
            class MainSystem {
                func update(context: AdaSystemContext) {}
            }
            """
            try source.write(to: root.appendingPathComponent("Sources/main.ada"), atomically: true, encoding: .utf8)
            let scene = root.appendingPathComponent(SceneDocumentFormat.defaultScenePath)
            try FileManager.default.createDirectory(at: scene.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SceneDocumentFormat.defaultSceneYAML(projectName: "A2UIWorkflow").write(to: scene, atomically: true, encoding: .utf8)
        }
    }

    static func makeAgent(project: EditorProjectReference?) -> EditorAgentViewModel {
        let settings = EditorAgentSettingsStore()
        var configuration = EditorAgentSettingsStore.shared.configuration
        if let fixture = argument("--a2ui-fixture=") {
            configuration.enabled = true
            configuration.target = .init(command: "/usr/bin/python3", arguments: [fixture])
        }
        do { try settings.save(configuration) } catch { log("settings FAIL: \(error.localizedDescription)") }
        return EditorAgentViewModel(project: project, settings: settings)
    }

    static func run(editor: EditorViewModel) async {
        guard enabled, !editor.didRunA2UISmoke else {
            return
        }
        editor.didRunA2UISmoke = true
        do {
            editor.showRightPanel = true
            editor.toolStrip.activeRightTool = "agentChat"
            let agent = editor.agent
            for _ in 0..<200 {
                if agent.activeSession != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            agent.mode = .ask
            agent.prompt = """
            Create an interactive NPC configuration form directly in chat using the advertised Ada A2UI catalog.
            Use surfaceId npc-config. TextFields npc-name and npc-greeting; single-string ChoicePicker npc-role with
            choices guide/Guide, merchant/Merchant, guard/Guard; Slider npc-health with min 1, max 100, step 1;
            and a repeatable toggle. Use required checks on name and a range check on health (1...100).
            Put both checks on the generate Button too.
            Bind fields to /npc/name, /npc/role, /npc/health, /npc/greeting and /npc/repeatable. Add a Button with ID generate,
            event name generate_npc_preview, and context including name, role, health, greeting, repeatable as path bindings.
            Use default name Guide, role guide, health 10. Emit compact JSONL inside an a2ui fence and end the turn.
            When I submit, generate a NEW preview surface with a unique surface ID and a Text title containing the submitted NPC name,
            the greeting and a dialog choice Button. Do not run tools or write files for this UI-only experiment.
            """
            log("sending initial form request via configured ACP agent")
            await agent.sendPromptAsync()
            log("initial reply complete")
            let sessionID = try require(agent.activeSession?.id, "Agent session missing")
            let ui = try require(agent.a2ui.sessions[sessionID], "A2UI session missing")
            _ = try require(ui.client.surfaces["npc-config"], "Agent did not return npc-config. \(agent.statusMessage ?? agent.currentConnectionState.title)")
            try await Task.sleep(for: .milliseconds(200))
            let window = try require(UIWindowManager.shared?.activeWindow ?? UIWindowManager.shared?.windows.values.first?.value, "Editor window missing")
            let container = try require(window.uiInspectableContainers().first, "Editor UI container missing")
            log("mounted container ready; surfaces: \(ui.records.keys.sorted())")
            try await capture(container, name: "before-input")
            let view = try require(container as? UIView, "Input view missing")
            let field = UINodeSelector.accessibilityIdentifier("a2ui.npc-config.npc-name")
            _ = try container.uiScrollToNode(matching: field)
            try await Task.sleep(for: .milliseconds(100))
            _ = try container.uiTapNode(matching: field)
            log("NPC name field focused")
            view.onKeyEvent(KeyEvent(window: window.id, keyCode: .a, modifiers: [.control], status: .down, time: 0, isRepeated: false))
            view.onTextInputEvent(TextInputEvent(window: window.id, text: "", action: .deleteBackward, time: 1))
            try await Task.sleep(for: .milliseconds(100))
            guard ui.client.surfaces["npc-config"]?.dataModel.value(at: ["npc", "name"]) == .string("") else {
                throw A2UIValidationError(message: "Native text deletion did not clear the name")
            }
            let generate = UINodeSelector.accessibilityIdentifier("a2ui.npc-config.generate")
            _ = try container.uiScrollToNode(matching: generate)
            _ = try container.uiTapNode(matching: generate)
            guard !agent.isSubmittingA2UI else { throw A2UIValidationError(message: "An invalid form was submitted") }
            _ = try container.uiScrollToNode(matching: field)
            _ = try container.uiTapNode(matching: field)
            view.onTextInputEvent(TextInputEvent(window: window.id, text: "Ada Guide", action: .insert, time: 0))
            let choice = UINodeSelector.accessibilityIdentifier("a2ui.npc-config.npc-role.option.merchant")
            _ = try container.uiScrollToNode(matching: choice)
            try await Task.sleep(for: .milliseconds(100))
            _ = try container.uiTapNode(matching: choice)
            let slider = UINodeSelector.accessibilityIdentifier("a2ui.npc-config.npc-health")
            _ = try container.uiScrollToNode(matching: slider)
            try await Task.sleep(for: .milliseconds(100))
            _ = try container.uiTapNode(matching: slider)
            guard ui.client.surfaces["npc-config"]?.dataModel.value(at: ["npc", "health"]) == .number(51) else {
                throw A2UIValidationError(message: "Native slider did not update health")
            }
            try await Task.sleep(for: .milliseconds(100))
            try await capture(container, name: "form")
            let submit = UINodeSelector.accessibilityIdentifier("a2ui.npc-config.generate")
            _ = try container.uiScrollToNode(matching: submit)
            try await Task.sleep(for: .milliseconds(100))
            let previousSurfaceIDs = Set(ui.client.surfaces.keys)
            _ = try container.uiTapNode(matching: submit)
            log("submitted configuration")
            for _ in 0..<9000 {
                if !agent.isSending, !agent.isSubmittingA2UI, !Set(ui.client.surfaces.keys).subtracting(previousSurfaceIDs).isEmpty { break }
                if ui.records["npc-config"]?.error != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let previewIDs = Set(ui.client.surfaces.keys).subtracting(previousSurfaceIDs)
            guard previewIDs.count == 1 else { throw A2UIValidationError(message: "Expected one new preview surface after form submission") }
            let previewID = try require(previewIDs.first, "Agent did not return a new preview after form submission")
            log("preview response ready")
            guard agent.activeSession?.id == sessionID else { throw A2UIValidationError(message: "Submission changed its owning chat") }
            try await capture(container, name: "preview", surfaceID: previewID)
            let open = UINodeSelector.accessibilityIdentifier("AdaEditor.Agent.A2UI.OpenDesigner.\(previewID)")
            _ = try container.uiScrollToNode(matching: open)
            try await Task.sleep(for: .milliseconds(150))
            _ = try container.uiTapNode(matching: open)
            log("opened designer")
            try await Task.sleep(for: .milliseconds(300))
            guard case let .ui(document)? = editor.workbench.activeDocument else {
                throw A2UIValidationError(message: "Preview did not open in the UI designer")
            }
            let model = try require(editor.workbench.uiSceneModels[document.id], "Native designer model was not mounted")
            guard !container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.UIScene.CanvasPanel")).isEmpty else {
                throw A2UIValidationError(message: "Designer canvas was not rendered")
            }
            let before = model.document
            var textID: String?
            model.document.root.visit { if textID == nil, $0.type == "Text" { textID = $0.id } }
            model.selectedID = try require(textID, "Preview has no editable Text")
            model.updateSelected { $0.arguments["text"] = .init(value: .string("Refined in Ada Studio")) }
            guard model.document != before, model.canUndo else { throw A2UIValidationError(message: "Designer edit was not undoable") }
            model.undo()
            guard model.document == before else { throw A2UIValidationError(message: "Designer undo failed") }
            model.redo()
            guard editor.workbench.saveActiveDocument() else { throw A2UIValidationError(message: "Designer save failed") }
            let path = try require(document.absolutePath, "Preview path missing")
            _ = try UISceneDocument.decode(String(contentsOfFile: path, encoding: .utf8))
            try await capture(container, name: "designer")
            if let root = agent.projectURL {
                let saved = try await EditorAgentSessionStore(projectURL: root).loadSession(id: sessionID)
                let restored = EditorAgentA2UISession(session: saved)
                guard restored.client.surfaces[previewID] != nil else { throw A2UIValidationError(message: "Saved conversation did not restore its preview") }
                try JSONEncoder().encode(saved).write(to: proofDirectory.appendingPathComponent("session.json"))
            }
            log("PASS: ACP stream -> native chat form -> input -> same-session action -> agent preview -> designer -> undo/redo -> save -> restore")
        } catch {
            if let session = editor.agent.activeSession {
                try? JSONEncoder().encode(session).write(to: proofDirectory.appendingPathComponent("failed-session.json"))
            }
            log("FAIL: \(error.localizedDescription)")
        }
    }

    private static var projectPath: String? { argument("--editor-project=") }
    private static var proofDirectory: URL {
        URL(fileURLWithPath: argument("--a2ui-proof-directory=") ?? "/private/tmp/adaeditor-a2ui-proof")
    }
    private static func argument(_ prefix: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw A2UIValidationError(message: message) }
        return value
    }
    private static func capture(_ container: any UIInspectableViewContainer, name: String, surfaceID: String = "npc-config") async throws {
        try await Task.sleep(for: .milliseconds(100))
        try FileManager.default.createDirectory(at: proofDirectory, withIntermediateDirectories: true)
        let target = name == "designer" ? "AdaEditor.UIScene.CanvasPanel" : "AdaEditor.Agent.A2UI.Surface.\(surfaceID)"
        let diagnostics = try container.uiLayoutDiagnostics(matching: .accessibilityIdentifier(target), subtreeDepth: 3)
        try JSONEncoder().encode(diagnostics).write(to: proofDirectory.appendingPathComponent("\(name)-tree.json"))
    }
    private static func log(_ text: String) {
        FileHandle.standardOutput.write(Data(("Studio A2UI " + text + "\n").utf8))
    }
}
#endif
