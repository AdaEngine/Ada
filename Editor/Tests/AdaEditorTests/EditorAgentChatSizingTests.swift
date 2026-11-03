@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import Math
import Testing

@testable import AdaEditor

@Suite("Agent workspace chat sizing", .serialized)
@MainActor
struct EditorAgentChatSizingTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "AgentChatSizingTests")))
        }
    }

    @Test("Retry and New Session remain at the toolbar's right edge", arguments: [Float(420), 800, 2000])
    func trailingActions(width: Float) async throws {
        let model = makeModel()
        let container = makeContainer(model, width: width)
        await settle(container)
        let toolbar = try frame("AdaEditor.Agent.ConversationToolbar", in: container)
        let retry = try frame("AdaEditor.Agent.Retry", in: container)
        let add = try frame("AdaEditor.Agent.NewSession", in: container)
        #expect(abs(toolbar.width - width) < 1)
        #expect(abs(toolbar.maxX - add.maxX - 8) < 1)
        #expect(add.minX > retry.maxX)
        #expect(abs(add.minX - retry.maxX - 6) < 1)
        #expect(retry.width > 20)
    }

    @Test("Messages and composer share a centered column without narrowing the header", arguments: [Float(420), 800, 1024, 2000])
    func contentColumn(width: Float) async throws {
        let model = makeModel()
        let container = makeContainer(model, width: width)
        await settle(container)
        let column = try frame("AdaEditor.Agent.ContentColumn", in: container)
        let transcript = try frame("AdaEditor.Agent.Transcript", in: container)
        let composer = try frame("AdaEditor.Agent.Composer", in: container)
        let header = try frame("AdaEditor.Agent.Header", in: container)
        #expect(abs(column.width - min(width, EditorAgentSidebar.maximumContentWidth)) < 1)
        #expect(abs(column.midX - width / 2) < 1)
        #expect(abs(transcript.minX - column.minX) < 1)
        #expect(abs(transcript.maxX - column.maxX) < 1)
        #expect(composer.minX >= column.minX && composer.maxX <= column.maxX)
        #expect(abs(composer.midX - column.midX) < 1)
        #expect(abs(header.width - width) < 1)
        #expect(abs(column.height - (760 - 34 - 38)) < 1)
        #expect(composer.maxY >= 760 - 24)
        #expect(composer.minY >= transcript.maxY - 1)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Agent.AddContext"))
        await settle(container)
        let context = try frame("AdaEditor.Agent.ContextSearch", in: container)
        #expect(context.minX >= column.minX && context.maxX <= column.maxX)
    }

    @Test("Long drafts wrap inside the composer without horizontal scrolling", arguments: [Float(320), 800, 2000])
    func promptWrapsToComposerWidth(width: Float) async throws {
        let model = makeModel()
        let original = String(repeating: "Составим с тобой основное геймплейное ядро игры и дизайн документ, чтобы по нему двигаться. ", count: 10)
        model.prompt = original
        let container = makeContainer(model, width: width)
        await settle(container)
        let node = try #require(editorNode(in: container.viewTree.rootNode))
        let scroll = try #require(node.nearestScrollView())
        let composer = try frame("AdaEditor.Agent.Composer", in: container)
        #expect(scroll.axis == [.vertical])
        #expect(scroll.frame.width <= composer.width)
        #expect(node.wrappedRows().count > 2)
        #expect(node.wrappedRows().map(\.line.text).joined() == original)
        node.setSelection(to: original.count)
        node.ensureCaretVisibleIfNeeded()
        #expect(scroll.contentOffset.x == 0)
        #expect(scroll.contentOffset.y > 0)
        #expect(node.caretRect().maxX <= scroll.frame.width + 1)
        #expect(node.caretViewportRect().maxY <= scroll.frame.height + 1)
        #expect(model.prompt == original)
    }

    @Test("Resizing reflows unbroken Unicode drafts and preserves selection")
    func promptReflowsWithoutChangingDraft() async throws {
        let model = makeModel()
        let original = String(repeating: "ДлинныйТекст👩🏽‍💻世界", count: 100)
        model.prompt = original
        let container = makeContainer(model, width: 360)
        await settle(container)
        let node = try #require(editorNode(in: container.viewTree.rootNode))
        let scroll = try #require(node.nearestScrollView())
        let narrowRowCount = node.wrappedRows().count
        #expect(narrowRowCount > 2)
        node.selectionAnchor = 5
        node.selectionHead = 40
        let selectedText = node.selectedText()
        container.frame.size.width = 1000
        container.bounds.size = container.frame.size
        await settle(container)
        #expect(editorNode(in: container.viewTree.rootNode) === node)
        #expect(node.wrappedRows().count < narrowRowCount)
        #expect(node.wrappedRows().map(\.line.text).joined() == original)
        #expect(node.selectionRange == 5..<40)
        #expect(node.selectedText() == selectedText)
        #expect(scroll.contentOffset.x == 0)
        #expect(model.prompt == original)
    }

    private func editorNode(in node: ViewNode) -> TextEditorViewNode? {
        if let editor = node as? TextEditorViewNode { return editor }
        for child in node.transientEnvironmentChildren {
            if let editor = editorNode(in: child) { return editor }
        }
        return nil
    }

    private func makeModel() -> EditorAgentViewModel {
        let model = EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore(), service: FakeEditorAgentService())
        let sessions = (0..<4).map { EditorAgentSession(title: "Conversation \($0)") }
        model.activeSession = sessions[0]
        model.activeSession?.events = [
            .init(
                id: "reply",
                kind: .message,
                message: .init(role: .assistant, segments: [.init(kind: .text, text: "A reply with enough content to establish the transcript's reading width.")])
            )
        ]
        model.sessions = sessions.map(EditorAgentSessionSummary.init(session:))
        model.connectionState = .failed("Offline")
        return model
    }

    private func makeContainer(_ model: EditorAgentViewModel, width: Float) -> UIContainerView<EditorAgentSidebar> {
        let container = UIContainerView(rootView: EditorAgentSidebar(viewModel: model, presentation: .workspace))
        container.frame = Rect(x: 0, y: 0, width: width, height: 760)
        container.bounds.size = container.frame.size
        return container
    }

    private func frame(_ id: String, in container: UIContainerView<EditorAgentSidebar>) throws -> Rect {
        try #require(container.uiFindNodes(matching: .accessibilityIdentifier(id)).first).absoluteFrame
    }

    private func settle(_ container: UIContainerView<EditorAgentSidebar>) async {
        for _ in 0..<5 { await Task.yield(); container.layoutIfNeeded(); container.update(1 / 60) }
    }
}
