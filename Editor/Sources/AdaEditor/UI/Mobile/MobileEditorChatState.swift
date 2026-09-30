import Foundation
import Observation

struct MobileEditorChatSessionReference: Equatable, Sendable {
    let id: String
    let title: String
}

/// Project conversations belong to the app, so navigation cannot cancel or replace a running turn.
@MainActor
@Observable
final class MobileEditorChatState {
    private struct Conversation {
        var sessionID = "session-\(UUID().uuidString.lowercased())"
        var previousSession: MobileEditorChatSessionReference?
        var didCheckPreviousSession = false
        var events: [EditorAgentEvent] = []
        var status: String?
        var activity: EditorAgentActivityState = .idle
        var activityID: String?
    }

    var activeProjectID: UUID?
    private(set) var runningProjectID: UUID?
    private var conversations: [UUID: Conversation] = [:]
    private var generalStatus: String?

    var events: [EditorAgentEvent] {
        get { activeProjectID.flatMap { conversations[$0]?.events } ?? [] }
        set {
            guard let id = activeProjectID else { return }
            conversations[id, default: Conversation()].events = newValue
        }
    }

    var status: String? {
        get { activeProjectID.flatMap { conversations[$0]?.status } ?? generalStatus }
        set {
            guard let id = activeProjectID else { generalStatus = newValue; return }
            conversations[id, default: Conversation()].status = newValue
        }
    }

    var activity: EditorAgentActivityState { activeProjectID.flatMap { conversations[$0]?.activity } ?? .idle }
    var activityID: String? { activeProjectID.flatMap { conversations[$0]?.activityID } }
    var previousSession: MobileEditorChatSessionReference? { activeProjectID.flatMap { conversations[$0]?.previousSession } }

    func open(_ id: UUID) {
        activeProjectID = id
        if conversations[id] == nil { conversations[id] = Conversation() }
    }

    func sessionID(for id: UUID) -> String {
        if conversations[id] == nil { conversations[id] = Conversation() }
        return conversations[id, default: Conversation()].sessionID
    }

    func needsPreviousSession(for id: UUID) -> Bool {
        !(conversations[id]?.didCheckPreviousSession ?? false)
    }

    func setPreviousSession(_ session: MobileEditorChatSessionReference?, for id: UUID, sessionID: String) {
        guard conversations[id]?.sessionID == sessionID,
              conversations[id]?.didCheckPreviousSession == false else { return }
        conversations[id]?.previousSession = session
        conversations[id]?.didCheckPreviousSession = true
    }

    @discardableResult
    func resumePreviousSession(for id: UUID, expectedSessionID: String, events: [EditorAgentEvent]) -> Bool {
        guard runningProjectID != id, var conversation = conversations[id],
              conversation.sessionID == expectedSessionID, let previous = conversation.previousSession else { return false }
        conversation.sessionID = previous.id
        conversation.previousSession = nil
        conversation.events = events
        conversation.status = nil
        conversation.activity = .idle
        conversation.activityID = nil
        conversations[id] = conversation
        return true
    }

    func begin(_ id: UUID) {
        runningProjectID = id
        conversations[id, default: Conversation()].activity = .working
        conversations[id, default: Conversation()].activityID = UUID().uuidString
        setStatus("Agent is working…", for: id)
    }

    func record(_ event: EditorAgentEvent, for id: UUID) {
        var conversation = conversations[id, default: Conversation()]
        if let index = conversation.events.firstIndex(where: { $0.id == event.id }) {
            conversation.events[index] = event
        } else {
            conversation.events.append(event)
        }
        conversations[id] = conversation
    }

    func events(for id: UUID) -> [EditorAgentEvent] { conversations[id]?.events ?? [] }

    func setStatus(_ status: String, for id: UUID) {
        conversations[id, default: Conversation()].status = status
    }

    func finish(_ id: UUID, succeeded: Bool, status: String) {
        setStatus(status, for: id)
        conversations[id, default: Conversation()].activity = succeeded ? .completed : .failed
        if runningProjectID == id { runningProjectID = nil }
    }

    func load(_ events: [EditorAgentEvent], for id: UUID, sessionID: String? = nil) {
        guard runningProjectID != id,
              sessionID == nil || conversations[id]?.sessionID == sessionID else {
            return
        }
        conversations[id, default: Conversation()].events = events
    }
}
