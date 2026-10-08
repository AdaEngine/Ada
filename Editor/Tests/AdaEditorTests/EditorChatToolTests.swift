import AdaA2UI
@_spi(AdaEngine) import AdaEngine
import AdaUIDescription
import Foundation
import Testing

@testable import AdaEditor

@Suite("Interactive chat scene tools", .serialized)
@MainActor
struct EditorChatToolTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "ChatTools")))
        }
        EditorComponentRegistry.registerBuiltIns()
    }

    @Test func mobileCardSpawnsLocallyRepeatsAndUndoesAfterRestore() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = EditorMobileA2UIStore()
        let ui = store.prepare(sessionID: "mobile", projectURL: fixture.root, events: [], identity: "provider")
        let event = try form(revision: fixture.revision)
        ui.onSubmission = { submission in #expect(store.performLocal(submission)) }
        ui.beginRun(agentIdentity: "provider")
        // Exercise progressive delivery through the same parser as the mobile stream.
        let text = try #require(event.message?.segments.first?.text)
        for index in text.indices {
            ui.receive(.init(id: event.id, kind: .message, message: .init(role: .assistant, segments: [.init(kind: .text, text: String(text[...index]))])))
        }
        ui.finishRun(cancelled: false)
        #expect(ui.eventErrors.isEmpty)
        var transcript = EditorAgentTranscript(events: [event], sessionID: "mobile")
        transcript.a2uiPresentation = .init(session: ui, isEnabled: true, agentIdentity: "provider",
                                            onUndo: { store.undo(surfaceID: $0, sessionID: "mobile") })
        let container = UIContainerView(rootView: transcript.theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 390, height: 844)
        container.layoutSubviews()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("a2ui.tool.apply"))
        let service = EditorAgentSceneToolService(projectURL: fixture.root)
        #expect(try service.snapshot(relativePath: Self.path).model.entities.count == 4)
        #expect(ui.records["tool"]?.state == .ready)
        #expect(ui.records["tool"]?.lastApplication?.changeID != nil)
        container.layoutSubviews()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("a2ui.tool.apply"))
        #expect(try service.snapshot(relativePath: Self.path).model.entities.count == 6)
        #expect(store.persistenceError == nil)

        var savedEvent = event
        savedEvent.id = "persisted-provider-message"
        let restoredStore = EditorMobileA2UIStore()
        let restored = restoredStore.prepare(sessionID: "mobile", projectURL: fixture.root, events: [savedEvent], identity: "provider")
        #expect(restored.surfaceIDs(for: savedEvent.id) == ["tool"])
        #expect(restored.displayTexts[savedEvent.id]?.contains("```a2ui") == false)
        #expect(restored.records["tool"]?.lastApplication == ui.records["tool"]?.lastApplication)
        restoredStore.undo(surfaceID: "tool", sessionID: "mobile")
        #expect(try service.snapshot(relativePath: Self.path).model.entities.count == 4)
        #expect(restored.records["tool"]?.lastApplication == nil)
        #expect(restored.records["tool"]?.error == nil)
    }

    @Test func desktopApplyUsesWorkbenchHistoryAndNeverStartsAnotherModelTurn() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Chat", buildSystem: .adaScript), at: fixture.root)
        let settings = EditorAgentSettingsStore()
        var configuration = AdaProjectAgent()
        configuration.enabled = true
        configuration.target.command = "/chat-tool-fixture"
        try settings.save(configuration)
        let service = ChatToolAgent(form: try form(revision: fixture.revision))
        let agent = EditorAgentViewModel(project: .init(name: "Chat", path: fixture.root.path), settings: settings, service: service)
        await agent.loadSessions()
        let editor = EditorViewModel(project: .init(name: "Chat", path: fixture.root.path), agent: agent)
        let content = try String(contentsOf: fixture.root.appendingPathComponent(Self.path), encoding: .utf8)
        editor.workbench.open(.scene(.init(id: "scene:Assets/Scenes/Main.ascn", title: "Main.ascn", relativePath: Self.path,
                                           absolutePath: fixture.root.appendingPathComponent(Self.path).path, content: content, lastSavedContent: content,
                                           isReadOnly: false, sceneModel: try EditorSceneModel.decode(from: content), errorMessage: nil,
                                           isDirty: false, statusMessage: nil, loadSummary: EditorSceneFileLoader.summary(from: content))))
        agent.prompt = "Make a spawner"
        await agent.sendPromptAsync()
        agent.prompt = "My unsent draft"
        let sessionID = try #require(agent.activeSession?.id)
        let ui = try #require(agent.a2ui.sessions[sessionID])
        let container = UIContainerView(rootView: EditorAgentTranscript(viewModel: agent).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 600, height: 800)
        container.layoutSubviews()
        #expect(ui.records["tool"]?.state == .ready)
        #expect(agent.agentEnabled && !agent.isSending && !agent.isSubmittingA2UI)
        #expect(ui.records["tool"]?.agentIdentity == settings.configuration.target.sessionIdentity)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("a2ui.tool.apply"))
        for _ in 0..<3 { await Task.yield() }
        #expect(ui.records["tool"]?.lastApplication != nil, "State: \(String(describing: ui.records["tool"]))")
        #expect(editor.workbench.activeSceneDocument?.sceneModel?.entities.count == 4)
        #expect(await service.count() == 1)
        #expect(agent.prompt == "My unsent draft")
        #expect(ui.records["tool"]?.error == nil)
        agent.undoA2UITool(surfaceID: "tool")
        #expect(editor.workbench.activeSceneDocument?.sceneModel?.entities.count == 2)
        #expect(editor.workbench.performDocumentHistory(redo: true))
        #expect(editor.workbench.activeSceneDocument?.sceneModel?.entities.count == 4)
    }

    @Test func staleCardsAndUnknownActionsDoNotModifyScene() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = EditorMobileA2UIStore()
        let ui = store.prepare(sessionID: "stale", projectURL: fixture.root, events: [], identity: "provider")
        ui.beginRun(agentIdentity: "provider")
        ui.receive(try form(revision: fixture.revision))
        ui.finishRun(cancelled: false)
        ui.onSubmission = { _ = store.performLocal($0) }
        let service = EditorAgentSceneToolService(projectURL: fixture.root)
        let changed = try service.apply(relativePath: Self.path, expectedRevision: fixture.revision, operations: [.renameEntity(id: "npc", name: "Changed outside card")])
        ui.client.surfaces["tool"]?.scene.context.perform("event:apply")
        #expect(ui.records["tool"]?.error?.contains("revision conflict") == true)
        #expect(try service.snapshot(relativePath: Self.path).model == changed.model)
        let unknown = try request(name: "editor.shell.run", context: ["command": .string("bad")])
        #expect(throws: EditorAgentA2UIToolRequest.Failure.self) { try unknown.operations(in: changed.model) }
        let escaping = try request(name: "editor.scene.spawn", context: ["path": .string("../Outside.ascn")])
        #expect(throws: EditorAgentSceneToolError.self) { try service.snapshot(relativePath: escaping.string("path")) }
    }

    @Test func invalidRevisionBindingCannotCommitAndSessionsStayProjectScoped() throws {
        let first = try fixture()
        let second = try fixture()
        defer {
            try? FileManager.default.removeItem(at: first.root)
            try? FileManager.default.removeItem(at: second.root)
        }
        let store = EditorMobileA2UIStore()
        let ui = store.prepare(sessionID: "same-provider-id", projectURL: first.root, events: [], identity: "provider")
        ui.beginRun(agentIdentity: "provider")
        ui.receive(try form(revision: first.revision))
        ui.finishRun(cancelled: false)
        let event = A2UIClientEvent(envelope: .object(["action": .object([
            "name": .string("editor.scene.spawn"), "context": .object([
                "path": .string(Self.path), "entityID": .string("npc"), "count": .number(2), "spacing": .number(3),
                "expectedRevision": .string(first.revision), "revisionBinding": .string("/missing")
            ])
        ])]))
        #expect(store.performLocal(.init(sessionID: ui.id, surfaceID: "tool", agentIdentity: "provider", event: event)))
        #expect(ui.records["tool"]?.error != nil)
        #expect(try EditorAgentSceneToolService(projectURL: first.root).snapshot(relativePath: Self.path).revision == first.revision)
        let other = store.prepare(sessionID: ui.id, projectURL: second.root, events: [], identity: "provider")
        #expect(other !== ui)
        #expect(other.records.isEmpty)
        #expect(ui.onSubmission == nil)
    }

    @Test func colorChangesPreserveOtherPropertiesAndRejectNonColorFields() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = EditorAgentSceneToolService(projectURL: fixture.root)
        let before = try service.snapshot(relativePath: Self.path)
        let type = EditorBuiltInComponentType.sprite
        let context: [String: UIValue] = ["entityID": .string("npc"), "typeName": .string(type), "field": .string("tintColor"), "color": .string("#3366FF80")]
        let tool = try request(name: "editor.scene.setColor", context: context)
        let result = try service.apply(relativePath: Self.path, expectedRevision: before.revision, operations: tool.operations(in: before.model))
        let payload = try #require(result.model.entities.first { $0.id == "npc" }?.components[type])
        #expect(payload["tintColor"]?.colorValue?.blue == 1)
        #expect(abs((payload["tintColor"]?.colorValue?.alpha ?? 0) - 128.0 / 255) < 0.001)
        #expect(payload.filter { $0.key != "tintColor" } == before.model.entities.first { $0.id == "npc" }?.components[type]?.filter { $0.key != "tintColor" })
        var invalid = context
        invalid["field"] = .string("texture")
        #expect(throws: EditorAgentA2UIToolRequest.Failure.self) { try request(name: "editor.scene.setColor", context: invalid).operations(in: before.model) }
        #expect(try service.undo(changeID: result.changeID).model == before.model)
    }

    @Test func spawnPreservesSubtreesAndEnabledStateAndLimitsWholeBatch() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = EditorAgentSceneToolService(projectURL: fixture.root)
        let before = try service.snapshot(relativePath: Self.path)
        let source = try service.applying(operations: [.createEntity(id: "child", name: "NPC child", parentID: "npc", components: [:]), .setEntityEnabled(id: "child", enabled: false)], to: before.model)
        let context: [String: UIValue] = ["entityID": .string("npc"), "count": .number(2), "spacing": .number(3)]
        let tool = try request(name: "editor.scene.spawn", context: context)
        let result = try service.applying(operations: tool.operations(in: source), to: source)
        #expect(result.entities.count == 7)
        #expect(result.entities.filter { $0.name == "NPC child" && !$0.enabled }.count == 3)
        var oversized = context
        oversized["count"] = .number(100)
        #expect(throws: EditorAgentA2UIToolRequest.Failure.self) { try request(name: "editor.scene.spawn", context: oversized).operations(in: source) }
        var fractional = context
        fractional["count"] = .number(1.5)
        #expect(throws: EditorAgentA2UIToolRequest.Failure.self) { try request(name: "editor.scene.spawn", context: fractional).operations(in: source) }
    }

    @Test func structuredOperationsAreAtomicAndDesktopNoOpsCannotUndoOtherEdits() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = EditorAgentSceneToolService(projectURL: fixture.root)
        let before = try service.snapshot(relativePath: Self.path)
        let operations: [UIValue] = [
            .object(["op": .string("renameEntity"), "entityID": .string("npc"), "name": .string("Updated NPC")]),
            .object(["op": .string("setComponent"), "entityID": .string("npc"), "typeName": .string("Unavailable"), "payload": .object([:])])
        ]
        let tool = try request(name: "editor.scene.apply", context: ["operations": .array(operations)])
        #expect(throws: EditorAgentSceneToolError.self) {
            try service.apply(relativePath: Self.path, expectedRevision: before.revision, operations: tool.operations(in: before.model))
        }
        #expect(try service.snapshot(relativePath: Self.path) == before)
        let editor = EditorViewModel(project: .init(name: "Chat", path: fixture.root.path))
        let content = try before.model.encodedYAML()
        editor.workbench.open(.scene(.init(
            id: "scene:Assets/Scenes/Main.ascn", title: "Main.ascn", relativePath: Self.path,
            absolutePath: fixture.root.appendingPathComponent(Self.path).path, content: content, lastSavedContent: content,
            isReadOnly: false, sceneModel: before.model, errorMessage: nil, isDirty: false,
            statusMessage: nil, loadSummary: EditorSceneFileLoader.summary(from: content)
        )))
        let noOp = try request(name: "editor.scene.apply", context: [
            "path": .string(Self.path), "expectedRevision": .string(EditorAgentSceneToolService.revision(for: content)),
            "operations": .array([.object(["op": .string("renameEntity"), "entityID": .string("npc"), "name": .string("NPC")])])
        ])
        #expect(throws: EditorAgentA2UIToolRequest.Failure.self) { try editor.applyChatTool(noOp) }
        #expect(!editor.workbench.performDocumentHistory(redo: false))
    }

    @Test func mobileContextAdvertisesCardsAndSceneSnapshotTools() async throws {
        #expect(MobileEditorAgentContext.prompt("Make a color tool").contains("editor.scene.setColor"))
        let action = A2UIClientEvent(envelope: .object(["action": .object(["name": .string("generate_preview")])]))
        let prompt = MobileEditorAgentContext.prompt("Submitted color tool", visiblePrompt: "Submitted color tool", a2uiAction: action)
        #expect(prompt.contains("[A2UI user action]"))
        #expect(MobileEditorAgentContext.visibleText(prompt) == "Submitted color tool")
        #expect(EditorMobileAgentTools.tools().contains { $0.name == "editor.scene.get" })
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = await EditorMobileAgentToolService(projectURL: fixture.root).handle(name: "editor.scene.get", arguments: ["path": .string(Self.path)])
        #expect(result.ok)
        #expect(result.payload.contains(fixture.revision))
    }

    private static let path = "Assets/Scenes/Main.ascn"

    private func fixture() throws -> (root: URL, revision: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatToolTests-\(UUID())")
        let path = root.appendingPathComponent(Self.path)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var model = EditorSceneModel.default(projectName: "Chat")
        // Keep a minimal real scene with a reusable NPC template.
        model.entities = model.entities.filter { $0.id == "root" }
        model.entities.append(.init(id: "npc", name: "NPC", enabled: true, parent: "root", components: [
            EditorBuiltInComponentType.transform: EditorComponentRegistry.defaultPayload(for: EditorBuiltInComponentType.transform),
            EditorBuiltInComponentType.sprite: EditorComponentRegistry.defaultPayload(for: EditorBuiltInComponentType.sprite)
        ]))
        let content = try model.encodedYAML()
        try content.write(to: path, atomically: true, encoding: .utf8)
        return (root, EditorAgentSceneToolService.revision(for: content))
    }

    private func request(name: String, context: [String: UIValue]) throws -> EditorAgentA2UIToolRequest {
        try .init(.init(envelope: .object(["action": .object(["name": .string(name), "context": .object(context)])])))
    }

    private func form(revision: String) throws -> EditorAgentEvent {
        let context: [String: UIValue] = ["path": .string(Self.path), "entityID": .string("npc"),
                                          "expectedRevision": .object(["path": .string("/scene/revision")]), "revisionBinding": .string("/scene/revision"),
                                          "count": .object(["path": .string("/count")]), "spacing": .number(3)]
        let components: [UIValue] = [
            .object(["id": .string("root"), "component": .string("Column"), "children": .array([.string("count"), .string("apply")])]),
            .object(["id": .string("count"), "component": .string("Slider"), "value": .object(["path": .string("/count")]), "min": .number(1), "max": .number(10), "step": .number(1)]),
            .object(["id": .string("apply"), "component": .string("Button"), "text": .string("Spawn NPCs"), "action": .object(["event": .object(["name": .string("editor.scene.spawn"), "context": .object(context)])])])
        ]
        let bodies: [(String, UIValue)] = [
            ("createSurface", .object(["surfaceId": .string("tool"), "catalogId": .string(A2UIClient.catalogID)])),
            ("updateComponents", .object(["surfaceId": .string("tool"), "components": .array(components)])),
            ("updateDataModel", .object(["surfaceId": .string("tool"), "value": .object(["scene": .object(["revision": .string(revision)]), "count": .number(2)])]))
        ]
        let lines = try bodies.map { String(decoding: try JSONEncoder().encode(UIValue.object(["version": .string("v0.9.1"), $0.0: $0.1])), as: UTF8.self) }
        return .init(id: "live-reply", kind: .message, message: .init(role: .assistant, segments: [.init(kind: .text, text: "NPC tool\n```a2ui\n" + lines.joined(separator: "\n") + "\n```")]))
    }
}

private actor ChatToolAgent: EditorAgentServicing {
    let form: EditorAgentEvent
    private var sends = 0
    init(form: EditorAgentEvent) { self.form = form }
    func count() -> Int { sends }
    func connect(_ request: EditorAgentRunRequest, onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void,
                 onProjectFileChanged: @escaping @Sendable (String) async -> Void) async throws -> EditorAgentSessionConfiguration { .empty }
    func send(_ request: EditorAgentRunRequest, onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void,
              onProjectFileChanged: @escaping @Sendable (String) async -> Void) async throws -> EditorAgentRunResult {
        sends += 1
        await onEvent(form)
        return .init(upstreamSessionID: "chat-tool", assistantText: form.message?.segments.first?.text ?? "", stopReason: "end_turn", configuration: .empty)
    }
    func setConfiguration(sessionID: String, selectorID: String, valueID: String) async throws -> EditorAgentSessionConfiguration { .empty }
    func resolvePermission(requestID: String, optionID: String?) async {}
    func cancel(sessionID: String) async {}
    func shutdown() async {}
}
