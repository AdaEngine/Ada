@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Math
import Testing

@testable import AdaEditor

@Suite("Conversation layout", .serialized)
@MainActor
struct EditorAgentConversationLayoutTests {
    @Test("The first user message moves the same prompt from the top to the bottom", arguments: [false, true])
    func firstMessageDocksPrompt(workspace: Bool) async throws {
        guard AdaEngineStyleLayoutSpec.usesCompactWorkspace else {
            return
        }
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "ChatLayout")))
        }
        let model = EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore(), service: FakeEditorAgentService())
        model.activeSession = EditorAgentSession(title: "First turn")
        let root = EditorAgentSidebar(viewModel: model, presentation: workspace ? .workspace : .sidebar)
        let container = UIContainerView(rootView: root.theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: workspace ? 920 : 350, height: 700)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let prompt = UINodeSelector.accessibilityIdentifier("AdaEditor.Agent.Prompt")
        let initial = try container.uiNode(matching: prompt)
        #expect(initial.absoluteFrame.minY < 160)

        model.activeSession?.events.append(
            EditorAgentEvent(
                id: "first-user",
                kind: .message,
                message: .init(role: .user, segments: [.init(kind: .text, text: "Hello")])
            )
        )
        for _ in 0..<8 {
            await Task.yield()
            container.update(0.016)
            container.layoutIfNeeded()
        }
        let docked = try container.uiNode(matching: prompt)
        #expect(docked.absoluteFrame.minY > 500)
        #expect(docked.runtimeId == initial.runtimeId)
        let message = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.UserMessage.first-user"))
        #expect(message.absoluteFrame.maxY < docked.absoluteFrame.minY)
    }
}
