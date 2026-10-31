@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@Suite("Agent interface workspace", .serialized)
@MainActor
struct EditorAgentWorkspaceTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "AgentInterfaceTests")))
        }
    }

    @Test("The interface preference restores per project and defaults to Editor")
    func preferences() throws {
        let suite = "AgentInterface-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = EditorInterfaceState(projectPath: "/tmp/First", defaults: defaults)
        #expect(first.mode == .editor)
        first.mode = .agent
        #expect(EditorInterfaceState(projectPath: "/tmp/First/./", defaults: defaults).mode == .agent)
        #expect(EditorInterfaceState(projectPath: "/tmp/Second", defaults: defaults).mode == .editor)
        defaults.set("unknown", forKey: "AdaEditor.InterfaceMode./tmp/Second")
        #expect(EditorInterfaceState(projectPath: "/tmp/Second", defaults: defaults).mode == .editor)
    }

    @Test("Only completed diffs appear in the session file tree")
    func confirmedChanges() {
        let events = [
            change("Sources/Main.ada"), change("Sources/Main.ada"), change("Assets/Main.ascn"),
            change("failed.ada", status: .failed), change("pending.ada", status: .inProgress),
            change("read.ada", kind: .text), change("")
        ]
        #expect(EditorAgentSessionChanges.files(in: events).map(\.path) == ["Assets/Main.ascn", "Sources/Main.ada"])
    }

    @Test("Real toolbar switches the workspace without replacing dirty documents or agent state", arguments: [Float(1024), 1280, 1400], [false, true])
    func switchInterface(width: Float, nativeOrnaments: Bool) async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root)
        model.didStartEditorSession = true
        await model.agent.loadSessions()
        model.openAgentChangedFile("Sources/Main.ada")
        let documentID = try #require(model.workbench.activeDocument?.id)
        model.workbench.updateTextDocument(id: documentID) { $0.content = "unsaved edit"; $0.isDirty = true }
        model.showLeftPanel = false
        model.showRightPanel = true
        model.showBottomPanel = true
        model.agent.prompt = "Keep this draft"
        let agent = model.agent
        let sessionID = model.agent.activeSession?.id
        let container = UIContainerView(rootView: EditorView(project: model.project, viewModel: model, usesNativeOrnaments: nativeOrnaments).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: width, height: 900)
        container.bounds.size = container.frame.size
        await settle(container)
        defer { model.stopProjectFileWatching() }
        let modeFrame = try #require(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.InterfaceMode.agent")).first).absoluteFrame
        let searchFrame = try #require(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.ProjectSearch")).first).absoluteFrame
        #expect(modeFrame.maxX <= searchFrame.minX)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.InterfaceMode.agent"))
        await settle(container)
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.AgentWorkspace")).count == 1)
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.AgentWorkspace.Sessions")).count == 1)
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Prompt"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.InterfaceMode.editor"))
        await settle(container)
        #expect(model.interface.mode == .editor)
        #expect(model.agent === agent)
        #expect(model.agent.activeSession?.id == sessionID)
        #expect(model.agent.prompt == "Keep this draft")
        #expect(!model.showLeftPanel && model.showRightPanel && model.showBottomPanel)
        #expect(activeText(model)?.content == "unsaved edit")
        #expect(activeText(model)?.isDirty == true)
    }

    @Test("Changed-file buttons open a real project document beside the conversation", arguments: [Float(1024), 1400])
    func openResult(width: Float) async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root)
        await model.agent.loadSessions()
        model.agent.activeSession?.events = [change("Sources/Main.ada")]
        let container = UIContainerView(rootView: EditorAgentWorkspace(viewModel: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: width, height: 800)
        container.bounds.size = container.frame.size
        await settle(container)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AgentWorkspace.File.Sources/Main.ada"))
        await settle(container)
        #expect(activeText(model)?.relativePath == "Sources/Main.ada")
        #expect(activeText(model)?.content == "class Player {}")
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.AgentWorkspace.Artifact")).count == 1)
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Prompt"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AgentWorkspace.CloseArtifact"))
        await settle(container)
        #expect(!model.interface.showsArtifact)
        #expect(activeText(model)?.relativePath == "Sources/Main.ada")
    }

    @Test("Opening and closing the result keeps panels adjacent and fills the workspace", arguments: [Float(640), 768, 999, 1000, 1024, 1400, 2000, 2672])
    func artifactPanelGeometry(width: Float) async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root)
        await model.agent.loadSessions()
        model.openAgentChangedFile("Sources/Main.ada")
        model.interface.showsArtifact = false
        model.agent.prompt = "Keep this panel draft"
        let documentID = model.workbench.activeDocument?.id
        let container = UIContainerView(rootView: EditorAgentWorkspace(viewModel: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: width, height: 800)
        container.bounds.size = container.frame.size
        await settle(container)
        for _ in 0..<3 {
            _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AgentWorkspace.ToggleArtifact"))
            await settle(container)
            let artifact = try #require(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.AgentWorkspace.Artifact")).first).absoluteFrame
            let chat = container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Agent.Header")).first
            let leading: Float = width >= 680 ? min(310, max(220, width * 0.25)) + 8 : 0
            if width - leading - 44 >= 640 {
                let chatFrame = try #require(chat).absoluteFrame
                #expect(abs(artifact.minX - chatFrame.maxX - 8) < 1)
                #expect(chatFrame.width > 200)
            } else {
                #expect(chat == nil)
                let leading: Float = width >= 680 ? min(310, max(220, width * 0.25)) + 8 : 0
                #expect(abs(artifact.minX - leading) < 1)
            }
            #expect(abs(artifact.maxX - (width - 44)) < 1)
            _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AgentWorkspace.CloseArtifact"))
            await settle(container)
            let closedChat = try #require(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Agent.Header")).first).absoluteFrame
            #expect(abs(closedChat.maxX - (width - 44)) < 1)
            #expect(!model.interface.showsArtifact)
            #expect(model.agent.prompt == "Keep this panel draft")
            #expect(model.workbench.activeDocument?.id == documentID)
        }
    }

    @Test("Project search opens the result and discussing selected code returns to chat without sending")
    func searchAndSelectionRouting() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root)
        await model.agent.loadSessions()
        model.interface.mode = .agent
        model.showRightPanel = false
        let item = try #require(model.projectSidebar.items.first { $0.relativePath == "Sources/Main.ada" })
        model.openSearchResult(item)
        #expect(model.interface.showsArtifact)
        let document = try #require(activeText(model))
        model.chatAboutTextSelection(
            document: document,
            range: .init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 5)),
            text: "class"
        )
        #expect(!model.interface.showsArtifact)
        #expect(model.interface.mode == .agent)
        #expect(!model.showRightPanel)
        #expect(model.agent.codeSelection?.documentRelativePath == document.relativePath)
        #expect(model.agent.prompt.contains("class"))
        await Task.yield()
        #expect(!model.agent.isSending)
        #expect(model.agent.activeSession?.events.isEmpty == true)
        #expect(model.workbench.activeDocument?.id == document.id)
    }

    @Test("Agent file results cannot open outside the project, including symlinks")
    func containedResults() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root)
        model.openAgentChangedFile("../outside.ada")
        #expect(!model.interface.showsArtifact)
        #expect(model.agent.statusMessage == "The agent file is outside this project.")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Sources/External.ada"),
            withDestinationURL: root.deletingLastPathComponent().appendingPathComponent("outside.ada")
        )
        model.openAgentChangedFile("Sources/External.ada")
        #expect(!model.interface.showsArtifact)
        model.openAgentChangedFile("Sources/missing.ada")
        #expect(!model.interface.showsArtifact)
    }

    @Test("Switching sessions restores each draft, attachments and chat mode")
    func sessionDrafts() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try makeModel(root).agent
        await agent.loadSessions()
        let firstID = try #require(agent.activeSession?.id)
        agent.prompt = "First draft"
        await agent.loadSessions()
        #expect(agent.activeSession?.id == firstID && agent.prompt == "First draft")
        agent.mode = .plan
        agent.pendingAttachments = [EditorAgentAttachmentContext.attachment(forFileAt: root.appendingPathComponent("Sources/Main.ada"), projectURL: root)]
        try await agent.createSession(connectAutomatically: false)
        let secondID = try #require(agent.activeSession?.id)
        #expect(agent.prompt.isEmpty && agent.pendingAttachments.isEmpty)
        agent.prompt = "Second draft"
        let first = try #require(agent.sessions.first { $0.id == firstID })
        agent.selectSession(first)
        try await waitForSession(firstID, agent: agent)
        #expect(agent.prompt == "First draft")
        #expect(agent.pendingAttachments.count == 1)
        #expect(agent.mode == .plan)
        agent.selectSession(try #require(agent.sessions.first { $0.id == secondID }))
        try await waitForSession(secondID, agent: agent)
        #expect(agent.prompt == "Second draft")
        #expect(agent.pendingAttachments.isEmpty)
    }

    @Test("Changing the selected chat does not cancel or misroute a running reply")
    func backgroundSession() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceGateAgentService()
        let settings = EditorAgentSettingsStore()
        let agent = EditorAgentViewModel(project: .init(name: "Agent UI", path: root.path), settings: settings, service: service, notifications: EditorNotificationCenter())
        await agent.loadSessions()
        let firstID = try #require(agent.activeSession?.id)
        agent.prompt = "Keep working"
        let turn = Task { await agent.sendPromptAsync() }
        defer { Task { await service.finish() } }
        for _ in 0..<100 {
            if await service.isWaiting() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(agent.runningSessionID == firstID)
        try await agent.createSession(connectAutomatically: false)
        let secondID = try #require(agent.activeSession?.id)
        #expect(agent.isSending && secondID != firstID)
        #expect(!agent.canSend)
        await service.finish()
        await turn.value
        #expect(agent.activeSession?.id == secondID)
        #expect(agent.activeSession?.events.isEmpty == true)
        #expect(!agent.isSending && agent.runningSessionID == nil)
        let saved = try await EditorAgentSessionStore(projectURL: root).loadSession(id: firstID)
        #expect(saved.events.contains { $0.message?.segments.first?.text == "Finished original session" })
        #expect(await service.cancelCount == 0)
    }

    private func change(_ path: String, status: EditorAgentToolStatus = .completed, kind: EditorAgentToolContentKind = .diff) -> EditorAgentEvent {
        .init(
            kind: .toolCall,
            toolCall: .init(
                id: UUID().uuidString,
                title: "Edit",
                kind: "edit",
                status: status,
                content: [.init(kind: kind, path: path, newText: "changed")],
                locations: []
            )
        )
    }

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentInterface-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Agent UI"), at: root)
        try "class Player {}".write(to: root.appendingPathComponent("Sources/Main.ada"), atomically: true, encoding: .utf8)
        return root
    }

    private func makeModel(_ root: URL) throws -> EditorViewModel {
        let defaults = try #require(UserDefaults(suiteName: "AgentInterfaceModel-\(root.lastPathComponent)"))
        let agent = EditorAgentViewModel(
            project: .init(name: "Agent UI", path: root.path),
            settings: EditorAgentSettingsStore(),
            service: FakeEditorAgentService(),
            notifications: EditorNotificationCenter()
        )
        return EditorViewModel(
            project: .init(name: "Agent UI", path: root.path),
            agent: agent,
            interface: EditorInterfaceState(projectPath: root.path, defaults: defaults),
            autosaveDelay: .seconds(600)
        )
    }

    private func activeText(_ model: EditorViewModel) -> EditorTextDocument? {
        if case let .text(document) = model.workbench.activeDocument {
            return document
        }
        return nil
    }

    private func waitForSession(_ id: String, agent: EditorAgentViewModel) async throws {
        for _ in 0..<100 {
            if agent.activeSession?.id == id {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(agent.activeSession?.id == id)
    }

    private func settle<Content: View>(_ container: UIContainerView<Content>) async {
        for _ in 0..<5 { await Task.yield(); container.layoutIfNeeded(); container.update(1 / 60) }
    }
}

extension EditorAgentWorkspaceTests {
    @Test("Agent navigation opens real editors and previews while preserving edits and panel preferences", arguments: [Float(768), 1400])
    func navigatorRouting(width: Float) async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("preview.png")
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAw0lEQVR4nO3QMQ1CURTA0OcOVThAE3JwwAwO/nZzLqFDxyZNz+P5/lxxu78u+XX/6ADtN0AH" +
            "aL8BOkD7DdAB2j/bA6f9BugA7TdAB2i/ATpA+w3YHjjtN0AHaL8BOkD7DdAB2m/A9sBpvwE6QPsN0AHab4AO0H4DtgdO+w3QAdpvgA7QfgN0gPYbsD1w2m+A" +
            "DtB+A3SA9hugA7TfgO2B034DdID2G6ADtN8AHaD9BmwPnPYboAO03wAdoP0G6ADt//2AL6IBOsLaSzBFAAAAAElFTkSuQmCC"
        ))
        try png.write(to: imageURL)
        let model = try makeModel(root)
        await model.agent.loadSessions()
        model.interface.mode = .agent
        model.toolStrip.activeLeftTopTool = "sourceControl"
        model.showLeftPanel = false
        model.agent.prompt = "Keep my draft"
        let container = UIContainerView(rootView: EditorAgentWorkspace(viewModel: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: width, height: 800)
        container.bounds.size = container.frame.size
        await settle(container)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.ToolStrip.agent.files"))
        await settle(container)
        model.projectSidebar.expandAll()
        await settle(container)
        try await Task.sleep(for: .milliseconds(240))
        await settle(container)
        let viewport = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.ScrollView")).absoluteFrame
        #expect(viewport.height > 500)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.Main.ada"))
        await settle(container)
        let document = try #require(activeText(model))
        #expect(document.relativePath == "Sources/Main.ada")
        #expect(model.interface.showsArtifact)
        model.workbench.updateTextDocument(id: document.id) { $0.content = "unsaved"; $0.isDirty = true }
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.preview.png"))
        await settle(container)
        if case let .asset(asset) = model.workbench.activeDocument {
            #expect(asset.kind == .image)
        } else {
            Issue.record("The image should open in its asset preview")
        }
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AgentWorkspace.Navigator.Tab.workspaces"))
        await settle(container)
        let workspaces = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AgentWorkspace.Workspaces"))
        #expect(workspaces.absoluteFrame.width > 100)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AgentWorkspace.Workspace.\(document.id)"))
        await settle(container)
        #expect(activeText(model)?.content == "unsaved")
        #expect(activeText(model)?.id == document.id)
        // Ordinary document navigation saves the outgoing buffer.
        #expect(try String(contentsOf: root.appendingPathComponent("Sources/Main.ada"), encoding: .utf8) == "unsaved")
        #expect(model.agent.prompt == "Keep my draft")
        #expect(model.workbench.openDocuments.count == 2)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.ToolStrip.agent.sourceControl"))
        await settle(container)
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Git.Sidebar"))
        model.interface.showsArtifact = false
        await settle(container)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Git.View Diff"))
        await settle(container)
        #expect(model.interface.showsArtifact)
        if case .git = model.workbench.activeDocument {
            // The review uses the existing document workbench.
        } else {
            Issue.record("Source Control should open a diff editor")
        }
        #expect(model.toolStrip.activeLeftTopTool == "sourceControl")
        #expect(!model.showLeftPanel)
    }

    @Test("The mounted navigator switches languages and keeps its tabs within the sidebar")
    func navigatorLocalization() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = EditorLocalization.shared.preference
        defer { EditorLocalization.shared.preference = previous }
        let model = try makeModel(root)
        await model.agent.loadSessions()
        let container = UIContainerView(rootView: EditorAgentWorkspace(viewModel: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 1024, height: 800)
        container.bounds.size = container.frame.size
        await settle(container)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.ToolStrip.agent.files"))
        for language in [EditorLanguage.english, .russian] {
            EditorLocalization.shared.preference = language
            await settle(container)
            let files = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AgentWorkspace.Navigator.Tab.files")).absoluteFrame
            let workspaces = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AgentWorkspace.Navigator.Tab.workspaces")).absoluteFrame
            let close = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AgentWorkspace.Navigator.Close")).absoluteFrame
            let sidebar = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AgentWorkspace.Navigator")).absoluteFrame
            #expect(files.maxX <= workspaces.minX)
            #expect(workspaces.maxX <= close.minX)
            #expect(close.maxX <= sidebar.maxX)
            #expect(L10n.tr("Workspaces") == (language == .russian ? "Рабочие области" : "Workspaces"))
        }
    }

    @Test("The visible conversation divider resizes both panes without losing the draft")
    func resizeArtifact() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root)
        await model.agent.loadSessions()
        model.openAgentChangedFile("Sources/Main.ada")
        model.agent.prompt = "Draft during resize"
        let container = UIContainerView(rootView: EditorAgentWorkspace(viewModel: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 1600, height: 800)
        container.bounds.size = container.frame.size
        await settle(container)
        let artifact = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AgentWorkspace.Artifact")).absoluteFrame
        let handle = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AgentWorkspace.ResizeArtifact")).absoluteFrame
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ResizeHandle.Grip"))
        for (phase, offset) in [(MouseEvent.Phase.began, Float(0)), (.changed, 100), (.ended, 100)] {
            container.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: Point(handle.midX + offset, handle.midY), phase: phase, modifierKeys: [], time: 0))
            await settle(container)
        }
        let resized = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AgentWorkspace.Artifact")).absoluteFrame
        #expect(resized.width < artifact.width - 80)
        #expect(abs(resized.maxX - artifact.maxX) < 1)
        #expect(model.agent.prompt == "Draft during resize")
    }

    @Test("A long session list scrolls within its panel and keeps Settings visible")
    func sessionScrolling() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root)
        let store = EditorAgentSessionStore(projectURL: root)
        for index in 0..<40 {
            let date = Date(timeIntervalSince1970: 2000 - Double(index))
            try await store.saveSession(.init(id: "scroll-\(index)", title: "Session \(index)", createdAt: date, updatedAt: date), makeActive: false)
        }
        await model.agent.loadSessions()
        let container = UIContainerView(rootView: EditorAgentWorkspace(viewModel: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 1400, height: 500)
        container.bounds.size = container.frame.size
        await settle(container)
        let lastID = "AdaEditor.AgentWorkspace.Session.scroll-39"
        _ = try container.uiScrollToNode(matching: .accessibilityIdentifier(lastID))
        await settle(container)
        let last = try container.uiNode(matching: .accessibilityIdentifier(lastID)).absoluteFrame
        let scroll = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AgentWorkspace.Sessions.ScrollView")).absoluteFrame
        let settings = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AgentWorkspace.Settings")).absoluteFrame
        #expect(last.minY >= scroll.minY)
        #expect(last.maxY <= scroll.maxY + 1)
        #expect(settings.minY >= scroll.maxY)
        #expect(settings.maxY <= 500)
    }
}

private actor WorkspaceGateAgentService: EditorAgentServicing {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var cancelCount = 0
    func isWaiting() -> Bool { continuation != nil }
    func finish() { continuation?.resume(); continuation = nil }
    func connect(
        _ request: EditorAgentRunRequest,
        onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void,
        onProjectFileChanged: @escaping @Sendable (String) async -> Void
    ) async throws -> EditorAgentSessionConfiguration { .empty }
    func send(
        _ request: EditorAgentRunRequest,
        onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void,
        onProjectFileChanged: @escaping @Sendable (String) async -> Void
    ) async throws -> EditorAgentRunResult {
        await withCheckedContinuation { continuation = $0 }
        await onEvent(.init(kind: .message, message: .init(role: .assistant, segments: [.init(kind: .text, text: "Finished original session")])))
        return .init(upstreamSessionID: "upstream", assistantText: "Finished original session", stopReason: "end_turn", configuration: .empty)
    }
    func setConfiguration(sessionID: String, selectorID: String, valueID: String) async throws -> EditorAgentSessionConfiguration { .empty }
    func resolvePermission(requestID: String, optionID: String?) async {}
    func cancel(sessionID: String) async { cancelCount += 1; finish() }
    func shutdown() async { finish() }
}
