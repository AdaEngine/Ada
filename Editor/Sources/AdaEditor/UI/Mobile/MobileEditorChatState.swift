import Foundation
import Observation

/// Project conversations belong to the app, so navigation cannot cancel or replace a running turn.
@MainActor
@Observable
final class MobileEditorChatState {
    private struct Conversation {
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

    func open(_ id: UUID) {
        activeProjectID = id
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

    func load(_ events: [EditorAgentEvent], for id: UUID) {
        guard runningProjectID != id else { return }
        conversations[id, default: Conversation()].events = events
    }
}
