@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor
@Suite("Agent transcript grouping and following", .serialized)
struct EditorAgentTranscriptTests {
    func message(_ id: String, role: EditorAgentRole = .assistant, text: String = "Reply") -> EditorAgentEvent {
        EditorAgentEvent(id: id, kind: .message, message: EditorAgentMessage(role: role, segments: [.init(kind: .text, text: text)]))
    }

    func tool(_ id: String) -> EditorAgentEvent {
        EditorAgentEvent(
            id: id,
            kind: .toolCall,
            title: "Read \(id)",
            toolCall: .init(
                id: id,
                title: "Read \(id)",
                kind: "read",
                status: .completed,
                content: [],
                locations: []
            )
        )
    }

    @Test("Interleaved actions group per turn without hiding replies or pending approvals")
    func grouping() {
        let approval = EditorAgentEvent(
            id: "approval",
            kind: .permission,
            permission: .init(
                id: "permission",
                summary: "Allow edit?",
                options: [],
                state: .pending
            )
        )
        let events = [
            message("u1", role: .user), tool("a"), message("progress"), tool("b"), approval,
            EditorAgentEvent(id: "error", kind: .error, title: "Failed"), message("u2", role: .user), tool("c"),
        ]
        let rows = EditorAgentTranscriptEntry.grouped(events)
        #expect(rows.map(\.id) == ["u1", "actions:u1", "progress", "approval", "error", "u2", "actions:u2"])
        guard case let .actions(_, actions) = rows[1] else {
            Issue.record("Expected action group")
            return
        }
        #expect(actions.map(\.id) == ["a", "b"])
    }

    @Test("One collapsed section expands and keeps its identity as tools arrive")
    func disclosure() async throws {
        let model = makeModel()
        model.activeSession?.events = [message("u", role: .user)] + (0..<12).map { tool("tool-\($0)") }
        let container = makeContainer(model)
        await settle(container)
        let selector = UINodeSelector.accessibilityIdentifier("AdaEditor.Agent.Actions.actions:u")
        let before = try container.uiNode(matching: selector)
        #expect(throws: (any Error).self) { try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Event.tool-0")) }
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Agent.ToggleActions.actions:u"))
        await settle(container)
        #expect(try container.uiNode(matching: selector).absoluteFrame.height > before.absoluteFrame.height)
        model.activeSession?.events.append(tool("last"))
        await settle(container)
        #expect(try container.uiNode(matching: selector).runtimeId == before.runtimeId)
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Event.last"))
    }

    @Test("Initial history, appended messages and same-ID streamed growth follow the bottom")
    func following() async throws {
        let model = makeModel()
        model.activeSession?.events = (0..<20).map { message("m\($0)", text: "Message \($0)\nSecond line\nThird line") }
        let container = makeContainer(model)
        await settle(container)
        try expectBottom(container)
        model.activeSession?.events.append(message("last", text: "A new message"))
        await settle(container)
        try expectBottom(container)
        model.activeSession?.events[20].message?.segments[0].text = String(repeating: "Streamed line\n", count: 30)
        await settle(container)
        try expectBottom(container)
    }

    @Test("Reading earlier messages is preserved when another message arrives")
    func readingHistory() async throws {
        let model = makeModel()
        model.activeSession?.events = (0..<30).map { message("m\($0)", text: "Message \($0)\nSecond line\nThird line") }
        let container = makeContainer(model)
        await settle(container)
        for phase in [MouseEvent.Phase.began, .ended] {
            container.onMouseEvent(
                MouseEvent(
                    window: .empty,
                    button: .scrollWheel,
                    scrollDelta: phase == .began ? Point(0, 3) : .zero,
                    mousePosition: Point(150, 130),
                    phase: phase,
                    modifierKeys: [],
                    time: 0
                )
            )
        }
        await settle(container)
        let before = try container.uiNode(matching: .accessibilityIdentifier(EditorAgentTranscript.bottomID)).absoluteFrame
        #expect(before.minY > 300)
        let markerBefore = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Event.m20")).absoluteFrame.minY
        model.activeSession?.events.append(message("new"))
        await settle(container)
        let markerAfter = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Event.m20")).absoluteFrame.minY
        #expect(abs(markerAfter - markerBefore) < 1)
    }

    @Test("Long messages wrap in a narrow transcript")
    func wrapping() async throws {
        let model = makeModel()
        let text = String(repeating: "Длинный ответ агента должен переноситься. ", count: 8)
        model.activeSession?.events = [message("user", role: .user, text: text), message("reply", text: text)]
        let container = makeContainer(model)
        container.frame.size.width = 300
        container.bounds.size = container.frame.size
        await settle(container)
        for id in ["user", "reply"] {
            let frame = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Event.\(id)")).absoluteFrame
            #expect(frame.height > 80)
            #expect(frame.maxX <= 300)
        }
    }

    private func makeModel() -> EditorAgentViewModel {
        let model = EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore(), notifications: EditorNotificationCenter())
        model.activeSession = EditorAgentSession(title: "Transcript")
        return model
    }

    private func makeContainer(_ model: EditorAgentViewModel) -> UIContainerView<EditorAgentTranscript> {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "TranscriptTests")))
        }
        let container = UIContainerView(rootView: EditorAgentTranscript(viewModel: model))
        container.frame = Rect(x: 0, y: 0, width: 400, height: 300)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        return container
    }

    private func settle(_ container: UIContainerView<EditorAgentTranscript>) async {
        for _ in 0..<4 {
            await Task.yield()
            container.layoutIfNeeded()
            container.update(1 / 60)
        }
    }

    private func expectBottom(_ container: UIContainerView<EditorAgentTranscript>) throws {
        let frame = try container.uiNode(matching: .accessibilityIdentifier(EditorAgentTranscript.bottomID)).absoluteFrame
        #expect(frame.minY >= 0 && frame.maxY <= 300)
    }
}
