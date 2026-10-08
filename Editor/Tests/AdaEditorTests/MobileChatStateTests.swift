@testable import AdaEditor
import Foundation
import Testing

@MainActor
struct MobileChatStateTests {
    @Test
    func relaunchStartsFreshAndExplicitlyResumesThePreviousSession() {
        let project = UUID()
        let firstLaunch = MobileEditorChatState()
        firstLaunch.open(project)
        let oldID = firstLaunch.sessionID(for: project)
        let saved = [EditorAgentEvent(id: "saved", kind: .message)]
        firstLaunch.load(saved, for: project, sessionID: oldID)

        let relaunched = MobileEditorChatState()
        relaunched.open(project)
        let newID = relaunched.sessionID(for: project)
        #expect(newID != oldID)
        #expect(relaunched.events.isEmpty)
        relaunched.setPreviousSession(.init(id: oldID, title: "Forest adventure"), for: project, sessionID: newID)
        #expect(relaunched.previousSession?.title == "Forest adventure")
        relaunched.open(project)
        #expect(relaunched.sessionID(for: project) == newID)
        #expect(relaunched.resumePreviousSession(for: project, expectedSessionID: newID, events: saved))
        #expect(relaunched.sessionID(for: project) == oldID)
        #expect(relaunched.events.map(\.id) == ["saved"])
        #expect(relaunched.previousSession == nil)
        relaunched.load([], for: project, sessionID: newID)
        #expect(relaunched.events.map(\.id) == ["saved"])
    }

    @Test
    func sessionSwitchingCannotReplaceARunningTurnOrUseAStaleSelection() {
        let project = UUID()
        let state = MobileEditorChatState()
        state.open(project)
        let sessionID = state.sessionID(for: project)
        state.setPreviousSession(.init(id: "saved", title: "Previous"), for: project, sessionID: sessionID)
        state.begin(project)
        #expect(!state.resumePreviousSession(for: project, expectedSessionID: sessionID, events: []))
        #expect(state.sessionID(for: project) == sessionID)
        state.finish(project, succeeded: true, status: "Done")
        #expect(!state.resumePreviousSession(for: project, expectedSessionID: "outdated", events: []))
        #expect(state.resumePreviousSession(for: project, expectedSessionID: sessionID, events: []))
        state.setPreviousSession(.init(id: "stale", title: "Late lookup"), for: project, sessionID: sessionID)
        #expect(state.previousSession == nil)
    }

    @Test
    func projectSessionsAndPreviousSessionLinksRemainIndependent() {
        let state = MobileEditorChatState()
        let first = UUID()
        let second = UUID()
        state.open(first)
        let firstID = state.sessionID(for: first)
        state.setPreviousSession(.init(id: "previous-first", title: "First game"), for: first, sessionID: firstID)
        state.open(second)
        #expect(state.sessionID(for: second) != firstID)
        #expect(state.previousSession == nil)
        #expect(state.needsPreviousSession(for: second))
        state.open(first)
        #expect(state.previousSession?.id == "previous-first")
        #expect(!state.needsPreviousSession(for: first))
    }

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
