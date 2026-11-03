import Foundation
import Testing
@testable import AdaEditor

@MainActor
struct EditorAgentEventBatcherTests {
    private func delta(_ text: String, id: String = "reply", kind: EditorAgentMessageSegmentKind = .text) -> EditorAgentEvent {
        EditorAgentEvent(id: id, kind: .message, message: .init(role: .assistant, segments: [.init(kind: kind, text: text)]), isDelta: true)
    }

    @Test func burstKeepsEveryCharacterWithOnePublication() {
        var published: [EditorAgentEvent] = []
        let buffer = EditorAgentEventBatcher { published.append($0) }
        for _ in 0..<1_000 { buffer.receive(delta("Привет 👋 ")) }
        #expect(published.isEmpty)
        buffer.flush()
        #expect(published.count == 1)
        #expect(published.first?.message?.segments.first?.text == String(repeating: "Привет 👋 ", count: 1_000))
    }

    @Test func controlEventsAndReplacementsRetainOrder() {
        var published: [EditorAgentEvent] = []
        let buffer = EditorAgentEventBatcher { published.append($0) }
        buffer.receive(delta("Thinking", kind: .thinking))
        buffer.receive(delta("First"))
        buffer.receive(delta(" second"))
        let approval = EditorAgentEvent(id: "approve", kind: .permission, permission: .init(id: "p", summary: "Allow?", options: [], state: .pending))
        buffer.receive(approval)
        #expect(published.map(\.id) == ["reply", "reply", "approve"])
        #expect(published[1].message?.segments.first?.text == "First second")
        var replacement = delta("Replacement")
        replacement.isDelta = false
        buffer.receive(replacement)
        buffer.receive(delta(" more"))
        buffer.receive(EditorAgentEvent(id: "done", kind: .runStatus, title: "Done"))
        var events: [EditorAgentEvent] = []
        for event in published { EditorAgentEventReducer.upsert(event, into: &events) }
        #expect(events.first?.message?.segments.first?.text == "Replacement more")
        #expect(events.last?.id == "done")
    }

    @Test func partialResponseAppearsBeforeCompletion() async throws {
        var published: [EditorAgentEvent] = []
        let buffer = EditorAgentEventBatcher { published.append($0) }
        buffer.receive(delta("Still working"))
        for _ in 0..<100 where published.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(published.count == 1)
        #expect(published.first?.message?.segments.first?.text == "Still working")
    }

    @Test func snapshotProvidersPublishTheLatestTextWithoutConcatenatingSnapshots() {
        var published: [EditorAgentEvent] = []
        let buffer = EditorAgentEventBatcher { published.append($0) }
        for text in ["Hello", "Hello world", "Hello world 👋"] {
            var snapshot = delta(text)
            snapshot.isDelta = nil
            buffer.receive(snapshot)
        }
        #expect(published.isEmpty)
        buffer.receive(delta("!"))
        buffer.flush()
        var events: [EditorAgentEvent] = []
        for event in published { EditorAgentEventReducer.upsert(event, into: &events) }
        #expect(published.count == 2)
        #expect(events.first?.message?.segments.first?.text == "Hello world 👋!")
    }
}
