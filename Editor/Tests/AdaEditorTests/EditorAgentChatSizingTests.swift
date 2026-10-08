@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
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
