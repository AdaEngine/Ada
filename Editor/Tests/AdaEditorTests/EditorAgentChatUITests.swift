@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@Suite("Editor agent chat UI", .serialized)
@MainActor
struct EditorAgentChatUITests {
    @Test("Enter submits the prompt, while Shift Enter preserves multiline input")
    func enterSendsPrompt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentEnter-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Enter"), at: root)
        let service = FakeEditorAgentService()
        let model = EditorAgentViewModel(project: .init(name: "Enter", path: root.path), settings: EditorAgentSettingsStore(), service: service)
        await model.loadSessions()
        let container = makeContainer(model)
        let prompt = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Prompt")).absoluteFrame
        let point = Point(prompt.minX + 15, prompt.minY + 15)
        for phase in [MouseEvent.Phase.began, .ended] {
            container.onMouseEvent(MouseEvent(window: .empty, button: .left, mousePosition: point, phase: phase, modifierKeys: [], time: 0))
        }
        container.onTextInputEvent(TextInputEvent(window: .empty, text: "Hello", action: .insert, time: 0))
        container.onKeyEvent(KeyEvent(window: .empty, keyCode: .enter, modifiers: [.shift], status: .down, time: 1, isRepeated: false))
        #expect(model.prompt == "Hello\n")
        #expect(await service.recordedRequest() == nil)
        container.onTextInputEvent(TextInputEvent(window: .empty, text: "world", action: .insert, time: 2))
        container.onKeyEvent(KeyEvent(window: .empty, keyCode: .enter, modifiers: [], status: .down, time: 3, isRepeated: false))
        for _ in 0..<100 {
            if await service.recordedRequest() != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await service.recordedRequest()?.prompt == "Hello\nworld")
        #expect(model.prompt.isEmpty)
    }

    @Test("Header has one settings action and compact tabs have a deletion menu")
    func tabsAndSettings() throws {
        let model = EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore(), service: FakeEditorAgentService())
        _ = makeContainer(model)
        let first = EditorAgentSession(title: "First chat")
        let second = EditorAgentSession(title: "Second chat")
        model.activeSession = first
        model.sessions = [.init(session: first), .init(session: second)]
        var opened = false
        let container = UIContainerView(rootView: EditorAgentSidebar(viewModel: model, onOpenCatalog: { opened = true }))
        container.frame = Rect(x: 0, y: 0, width: 560, height: 820)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let a = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Session.\(first.id)"))
        let b = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Session.\(second.id)"))
        let header = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Header"))
        #expect(a.absoluteFrame.maxX < b.absoluteFrame.minX)
        #expect(a.absoluteFrame.height == 32)
        #expect(a.absoluteFrame.minY - header.absoluteFrame.maxY <= 3)
        #expect(throws: (any Error).self) { try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Connect")) }
        #expect(throws: (any Error).self) { try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Delete session")) }
        var menu: ContextMenuPresentation?
        let previous = ContextMenuPresentationCenter.present
        ContextMenuPresentationCenter.present = { menu = $0 }
        defer { ContextMenuPresentationCenter.present = previous }
        container.onMouseEvent(MouseEvent(
            window: RID(), button: .right, mousePosition: Point(b.absoluteFrame.midX, b.absoluteFrame.midY),
            phase: .began, modifierKeys: [], time: 0
        ))
        #expect(menu?.items.map(\.title) == ["Delete session"])
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Agent.OpenCatalog"))
        #expect(opened)
    }

    @Test("Connection failure shows Retry and a new session connects automatically")
    func automaticConnectionAndRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentRetry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Retry"), at: root)
        let settings = EditorAgentSettingsStore()
        try settings.save(AdaProjectAgent(enabled: true, target: AdaProjectAgentTarget(command: "/bin/echo")))
        let service = FakeEditorAgentService(connectionError: .providerFailure("Unavailable"))
        let model = EditorAgentViewModel(project: .init(name: "Retry", path: root.path), settings: settings, service: service)
        await model.loadSessions()
        for _ in 0..<100 {
            if case .failed = model.currentConnectionState { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .failed = model.currentConnectionState else {
            Issue.record("Expected automatic connection to fail")
            return
        }
        let container = makeContainer(model)
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Retry"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Retry"))
        for _ in 0..<100 {
            if case .failed = model.currentConnectionState, await service.connectionCount() >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await service.connectionCount() >= 2)
        try await model.createSession()
        for _ in 0..<100 {
            if await service.connectionCount() >= 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await service.connectionCount() >= 3)
    }

    @Test("Opening the agent panel connects a loaded session")
    func panelOpeningConnects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentOpen-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Open"), at: root)
        _ = try await EditorAgentSessionStore(projectURL: root).createSession()
        let settings = EditorAgentSettingsStore()
        let service = FakeEditorAgentService()
        let model = EditorAgentViewModel(project: .init(name: "Open", path: root.path), settings: settings, service: service)
        await model.loadSessions()
        #expect(await service.connectionCount() == 0)
        try settings.save(AdaProjectAgent(enabled: true, target: AdaProjectAgentTarget(command: "/bin/echo")))
        _ = makeContainer(model)
        for _ in 0..<100 {
            if await service.connectionCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await service.connectionCount() == 1)
    }

    @Test("Tab context menu deletes the clicked session and keeps the active session")
    func deleteClickedSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentDelete-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Delete"), at: root)
        let model = EditorAgentViewModel(project: .init(name: "Delete", path: root.path), settings: EditorAgentSettingsStore(), service: FakeEditorAgentService())
        await model.loadSessions()
        let oldSession = try #require(model.activeSession)
        try await model.createSession()
        let activeID = try #require(model.activeSession?.id)
        let container = makeContainer(model)
        let tab = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Session.\(oldSession.id)"))
        var menu: ContextMenuPresentation?
        let previous = ContextMenuPresentationCenter.present
        ContextMenuPresentationCenter.present = { menu = $0 }
        defer { ContextMenuPresentationCenter.present = previous }
        container.onMouseEvent(MouseEvent(
            window: RID(), button: .right, mousePosition: Point(tab.absoluteFrame.midX, tab.absoluteFrame.midY),
            phase: .began, modifierKeys: [], time: 0
        ))
        let delete = try #require(menu?.items.first?.action)
        delete()
        for _ in 0..<100 {
            if !model.sessions.contains(where: { $0.id == oldSession.id }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.sessions.contains(where: { $0.id == oldSession.id }))
        #expect(model.activeSession?.id == activeID)
    }

    @Test("Provider JSON errors remain readable instead of disappearing in Markdown")
    func providerFailurePresentation() {
        let failure = #"{"type":"error","status":400,"error":{"message":"Please upgrade Codex."}}"#
        #expect(EditorAgentProviderFailure.message(in: "Warning: upgrade required\n\n" + failure) == "Please upgrade Codex.")
        #expect(EditorAgentProviderFailure.message(in: "Normal reply") == nil)
        #expect(EditorAgentProviderFailure.message(in: "Example error:\n" + failure) == nil)
        #expect(EditorAgentProviderFailure.message(in: "```json\n" + failure + "\n```") == nil)
        #expect(EditorAgentProviderFailure.message(in: #"{"type":"error","message":"Example"}"#) == nil)
    }

    private func makeContainer(_ model: EditorAgentViewModel) -> UIContainerView<EditorAgentSidebar> {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "AgentChatUI")))
        }
        let container = UIContainerView(rootView: EditorAgentSidebar(viewModel: model))
        container.frame = Rect(x: 0, y: 0, width: 560, height: 820)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        return container
    }

    @Test("narrow composer keeps attachment and send controls visible without a skills button")
    func narrowComposer() async throws {
        let model = EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore(), service: FakeEditorAgentService())
        model.availableSkills = [
            EditorAgentSkill(
                id: "sample",
                name: "Sample",
                description: nil,
                localPath: "/tmp/sample",
                userInvocable: true,
                allowedTools: [],
                instructions: "Sample"
            )
        ]
        let container = makeContainer(model)
        container.frame.size.width = 300
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let add = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.AddContext"))
        let send = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Send"))
        #expect(add.absoluteFrame.width >= 24)
        #expect(send.absoluteFrame.width == 34)
        #expect(send.absoluteFrame.maxX <= 300)
        #expect(add.absoluteFrame.maxY == send.absoluteFrame.maxY - 2)
        #expect(throws: (any Error).self) {
            try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Skills"))
        }
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Agent.AddContext"))
        for _ in 0..<20 { await Task.yield() }
        container.layoutIfNeeded()
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.ContextSearch"))
    }

    @Test("slash suggestions support keyboard selection and insert without submitting a prompt")
    func completionKeyboard() async throws {
        let model = EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore(), service: FakeEditorAgentService())
        model.sessionConfiguration.commands = [
            .init(name: "compact", description: "Compact conversation"),
            .init(name: "help", description: "Get help"),
        ]
        let container = makeContainer(model)
        let prompt = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Prompt")).absoluteFrame
        let point = Point(prompt.minX + 15, prompt.minY + 15)
        for phase in [MouseEvent.Phase.began, .ended] {
            container.onMouseEvent(MouseEvent(window: .empty, button: .left, mousePosition: point, phase: phase, modifierKeys: [], time: 0))
        }
        container.onTextInputEvent(TextInputEvent(window: .empty, text: "/", action: .insert, time: 0))
        for _ in 0..<20 { await Task.yield() }
        container.layoutIfNeeded()
        #expect(model.prompt == "/")
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Completion.command:compact"))
        container.onKeyEvent(KeyEvent(window: .empty, keyCode: .arrowDown, modifiers: [], status: .down, time: 0, isRepeated: false))
        #expect(model.selectedCompletionIndex == 1)
        container.onKeyEvent(KeyEvent(window: .empty, keyCode: .enter, modifiers: [], status: .down, time: 0, isRepeated: false))
        for _ in 0..<20 { await Task.yield() }
        container.layoutIfNeeded()
        #expect(model.prompt == "/help ")
        #expect(model.autocompleteSuggestions.isEmpty)
        #expect(!model.isSending)
    }

    @Test("streamed text relayouts the existing message before completion")
    func streamingRelayout() async throws {
        let model = EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore(), service: FakeEditorAgentService())
        model.activeSession = EditorAgentSession(title: "Streaming")
        model.activeSession?.events = [
            EditorAgentEvent(
                id: "stream",
                kind: .message,
                message: EditorAgentMessage(role: .assistant, segments: [.init(kind: .text, text: "First delta")])
            )
        ]
        model.isSending = true
        let container = makeContainer(model)
        let selector = UINodeSelector.accessibilityIdentifier("AdaEditor.Agent.Event.stream")
        let before = try container.uiNode(matching: selector)
        model.activeSession?.events[0].message?.segments[0].text = String(repeating: "A streamed line of text.\n", count: 10)
        for _ in 0..<20 { await Task.yield() }
        container.layoutIfNeeded()
        let after = try container.uiNode(matching: selector)
        #expect(after.runtimeId == before.runtimeId)
        #expect(after.absoluteFrame.height > before.absoluteFrame.height)
        #expect(model.isSending)
    }

    @Test("service details collapse and composer has no empty context gap")
    func disclosureAndComposer() async throws {
        let model = EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore(), service: FakeEditorAgentService())
        model.activeSession = EditorAgentSession(title: "Layout")
        model.activeSession?.events = [EditorAgentEvent(id: "status", kind: .runStatus, title: "Session updated", details: String(repeating: "Details\n", count: 12))]
        let container = makeContainer(model)
        let selector = UINodeSelector.accessibilityIdentifier("AdaEditor.Agent.Event.status")
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Agent.ToggleActions.actions:initial"))
        for _ in 0..<20 { await Task.yield() }
        container.layoutIfNeeded()
        let before = try container.uiNode(matching: selector)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Agent.ToggleEvent.status"))
        for _ in 0..<20 { await Task.yield() }
        container.layoutIfNeeded()
        let expanded = try container.uiNode(matching: selector)
        #expect(expanded.absoluteFrame.height > before.absoluteFrame.height)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Agent.ToggleEvent.status"))
        for _ in 0..<20 { await Task.yield() }
        container.layoutIfNeeded()
        #expect(try container.uiNode(matching: selector).absoluteFrame.height == before.absoluteFrame.height)
        let composer = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Composer"))
        let handle = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.ResizeComposer"))
        #expect(handle.absoluteFrame.origin.y - composer.absoluteFrame.origin.y <= 10)
        #expect(composer.absoluteFrame.height < 190)
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Selector.model"))
    }
    @Test("composer drag changes editor height through pointer events")
    func resizeComposer() async throws {
        let container = makeContainer(EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore(), service: FakeEditorAgentService()))
        let prompt = UINodeSelector.accessibilityIdentifier("AdaEditor.Agent.Prompt")
        let before = try container.uiNode(matching: prompt).absoluteFrame
        let handle = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.ResizeComposer")).absoluteFrame
        let start = Point(handle.midX, handle.midY)
        for (phase, point) in [(MouseEvent.Phase.began, start), (.changed, start + Point(0, -72)), (.ended, start + Point(0, -72))] {
            container.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: point, phase: phase, modifierKeys: [], time: 0))
            for _ in 0..<10 { await Task.yield() }
        }
        container.layoutIfNeeded()
        let after = try container.uiNode(matching: prompt).absoluteFrame
        #expect(after.height == before.height + 72)
    }

    @Test("model control opens a menu with all advertised choices")
    func modelMenu() throws {
        let model = EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore(), service: FakeEditorAgentService())
        model.sessionConfiguration = EditorAgentSessionConfiguration(
            agentName: "Test",
            selectors: [
                EditorAgentConfigurationSelector(
                    id: "model",
                    name: "Model",
                    category: .model,
                    currentValueID: "a",
                    choices: [
                        .init(id: "a", name: "Model A", description: nil),
                        .init(id: "b", name: "Model B", description: nil),
                    ],
                    usesLegacyMethod: false
                )
            ]
        )
        let container = makeContainer(model)
        var menu: ContextMenuPresentation?
        let previous = ContextMenuPresentationCenter.present
        ContextMenuPresentationCenter.present = { menu = $0 }
        defer { ContextMenuPresentationCenter.present = previous }
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Selector.model"))
        #expect(menu?.items.map(\.title) == ["Model A", "Model B"])
        #expect(menu?.items.filter(\.isSelected).map(\.title) == ["Model A"])
    }

    @Test("short user bubble sits on the right and assistant text sits on the left")
    func messageAlignment() throws {
        let model = EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore(), service: FakeEditorAgentService())
        model.activeSession = EditorAgentSession(events: [
            EditorAgentEvent(id: "user", kind: .message, message: EditorAgentMessage(role: .user, segments: [.init(kind: .text, text: "Hello")])),
            EditorAgentEvent(id: "assistant", kind: .message, message: EditorAgentMessage(role: .assistant, segments: [.init(kind: .text, text: "Hello")])),
        ])
        let container = makeContainer(model)
        let user = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.EventContent.user")).absoluteFrame
        let assistant = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.EventContent.assistant")).absoluteFrame
        #expect(user.minX > 280)
        #expect(assistant.minX < 30)
        #expect(user.width < 140)
    }
}
