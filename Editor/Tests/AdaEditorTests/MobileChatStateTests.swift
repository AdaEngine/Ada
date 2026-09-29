@testable import AdaEditor
import Foundation
import Testing

@MainActor
struct MobileChatStateTests {
    @Test
    func navigationKeepsRunningTurnAndRoutesItsUpdatesToTheOriginalProject() {
        let state = MobileEditorChatState()
        let first = UUID()
        let second = UUID()
        state.open(first)
        state.begin(first)
        state.record(EditorAgentEvent(id: "reply", kind: .message, title: "First snapshot"), for: first)
        state.open(second)
        state.record(EditorAgentEvent(id: "reply", kind: .message, title: "Updated snapshot"), for: first)
        state.setStatus("Using files.write…", for: first)
        #expect(state.runningProjectID == first)
        #expect(state.events.isEmpty)
        #expect(state.status == nil)
        #expect(state.activity == .idle)

        state.open(first)
        #expect(state.events.count == 1)
        #expect(state.events.first?.title == "Updated snapshot")
        #expect(state.status == "Using files.write…")
        #expect(state.activity == .working)
        state.finish(first, succeeded: true, status: "Build succeeded")
        #expect(state.runningProjectID == nil)
        #expect(state.activity == .completed)
    }

    @Test
    func savedHistoryCannotReplaceAnActiveStream() {
        let state = MobileEditorChatState()
        let project = UUID()
        state.open(project)
        state.begin(project)
        state.record(EditorAgentEvent(id: "live", kind: .message), for: project)
        state.load([], for: project)
        #expect(state.events.map(\.id) == ["live"])
        state.finish(project, succeeded: false, status: "Request failed")
        state.load([EditorAgentEvent(id: "saved", kind: .message)], for: project)
        #expect(state.events.map(\.id) == ["saved"])
        #expect(state.activity == .failed)
    }
}
