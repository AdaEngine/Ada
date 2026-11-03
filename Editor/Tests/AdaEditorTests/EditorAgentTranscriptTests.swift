@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) @testable import AdaUI
import Foundation
import Math
import Observation
import Synchronization
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

    @Test("Thoughts and actions precede the reply, while completion status stays hidden")
    func responseOrder() {
        let mixed = EditorAgentEvent(
            id: "assistant",
            kind: .message,
            message: .init(role: .assistant, segments: [
                .init(kind: .thinking, text: "Considering the request"),
                .init(kind: .text, text: "Hello"),
            ])
        )
        let events = [
            message("user", role: .user), mixed, tool("read"),
            EditorAgentEvent(id: "done", kind: .runStatus, title: "Done", details: "end_turn"),
        ]
        let rows = EditorAgentTranscriptEntry.grouped(events)
        #expect(rows.map(\.id) == ["user", "actions:user", "assistant"])
        guard case let .actions(_, actions) = rows[1] else {
            Issue.record("Expected action group")
            return
        }
        #expect(actions.map(\.id) == ["assistant:thinking", "read"])
        #expect(actions[0].message?.segments.map(\.kind) == [.thinking])
        guard case let .event(reply) = rows[2] else {
            Issue.record("Expected reply")
            return
        }
        #expect(reply.message?.segments.map(\.kind) == [.text])
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
        // The UI tick can sample the new model before the observed row has reconciled.
        container.update(1 / 60)
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

    @Test("Streamed text does not invalidate session chrome")
    func sessionChromeIsolation() {
        let model = makeModel()
        model.activeSession?.events = [message("reply")]
        let changed = Mutex(false)
        withObservationTracking {
            _ = model.activeSessionID
            _ = model.activeSessionTitle
            _ = model.hasActiveSessionEvents
        } onChange: {
            changed.withLock { $0 = true }
        }
        model.activeSession?.events[0].message?.segments[0].text = "Reply grows"
        #expect(!changed.withLock { $0 })
        model.activeSession = EditorAgentSession(title: "Another session")
        #expect(changed.withLock { $0 })
    }

    @Test("Growing one response keeps history rows and list topology unobserved")
    func streamingRowIsolation() async throws {
        let model = makeModel()
        model.activeSession?.events = (0..<40).map { message("history-\($0)", text: "## Reply \($0)\n\nSome **formatted** history with `code`.") }
        let container = makeContainer(model)
        await settle(container)
        let oldRow = try #require(model.transcript.rows.first)
        let oldNode = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Event.history-0"))
        let changed = Mutex(false)
        withObservationTracking {
            _ = model.transcript.rows
            _ = oldRow.entry
        } onChange: { changed.withLock { $0 = true } }
        let countersWereEnabled = UILayoutDebugCounters.isEnabled
        UILayoutDebugCounters.isEnabled = true
        UILayoutDebugCounters.reset()
        defer { UILayoutDebugCounters.isEnabled = countersWereEnabled }
        model.activeSession?.events[39].message?.segments[0].text = "## Growing reply\n\n" + String(repeating: "More **text**. ", count: 20)
        await settle(container)
        #expect(!changed.withLock { $0 })
        #expect(try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Event.history-0")).runtimeId == oldNode.runtimeId)
        // A local response update must not reconcile all forty formatted history cards.
        #expect(UILayoutDebugCounters.snapshot.rebuilds > 0)
        #expect(UILayoutDebugCounters.snapshot.rebuilds < 100)
    }

    @Test("Markdown code, quotes and tables lay out inside a narrow transcript")
    func markdownBlocks() async throws {
        let model = makeModel()
        model.activeSession?.events = [message("markdown", text: """
        # Заголовок

        - **Готово**
        - [Документация](https://adaengine.org)

        ```swift
        let literal = "**literal**"
        let longLine = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"
        ```

        > Цитата

        | Имя | Описание |
        | --- | --- |
        | Куб | Очень длинное описание, которое должно переноситься на несколько строк без обрезания текста |
        """)]
        let container = makeContainer(model)
        container.frame.size.width = 300
        container.bounds.size = container.frame.size
        await settle(container)
        for kind in ["Code", "Quote", "Table"] {
            let frame = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Markdown.\(kind)")).absoluteFrame
            #expect(frame.height > 0)
            #expect(frame.maxX <= 300)
        }
        let table = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Markdown.Table")).absoluteFrame
        #expect(table.height > 90)
    }

    @Test("A standalone transcript presents its initial history")
    func standaloneHistory() async throws {
        let container = makeContainer(EditorAgentTranscript(events: [message("standalone", text: "## Hello\n\nA reply")], sessionID: "standalone-session"))
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Event.standalone"))
        await settle(container)
        let frame = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Event.standalone")).absoluteFrame
        #expect(frame.height > 20)
        try expectBottom(container)
    }

    private func makeModel() -> EditorAgentViewModel {
        let model = EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore(), notifications: EditorNotificationCenter())
        model.activeSession = EditorAgentSession(title: "Transcript")
        return model
    }

    private func makeContainer(_ model: EditorAgentViewModel) -> UIContainerView<EditorAgentTranscript> {
        makeContainer(EditorAgentTranscript(viewModel: model))
    }

    private func makeContainer(_ transcript: EditorAgentTranscript) -> UIContainerView<EditorAgentTranscript> {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "TranscriptTests")))
        }
        let container = UIContainerView(rootView: transcript)
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
