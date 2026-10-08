import AdaA2UI
import AdaUIDescription
import Foundation
import Observation

@MainActor @Observable
final class EditorAgentA2UISession {
    let id: String
    let client = A2UIClient()
    private(set) var records: [String: EditorAgentA2UISurfaceRecord] = [:]
    private(set) var eventErrors: [String: String] = [:]
    private(set) var displayTexts: [String: String] = [:]
    @ObservationIgnored private var streams: [String: EditorAgentA2UIStream] = [:]
    @ObservationIgnored private var sourceTexts: [String: String] = [:]
    @ObservationIgnored private var touched = Set<String>()
    @ObservationIgnored private var currentEventID = ""
    @ObservationIgnored private var agentIdentity: String?
    @ObservationIgnored private var restoring = false
    @ObservationIgnored var onRecordsChanged: (([EditorAgentA2UISurfaceRecord]) -> Void)?
    @ObservationIgnored var onSubmission: ((EditorAgentA2UISubmission) -> Void)?

    init(session: EditorAgentSession) {
        id = session.id
        agentIdentity = session.agentTargetIdentity
        restoring = true
        client.onSurfaceChanged = { [weak self] surfaceID in self?.surfaceChanged(surfaceID) }
        client.onEvent = { [weak self] event in self?.receiveClientEvent(event) }
        if let saved = session.a2uiSurfaces {
            for record in saved {
                do {
                    for message in record.messages { try client.receive(JSONEncoder().encode(message)) }
                    records[record.id] = record
                    if record.state == .receiving || record.state == .submitting {
                        records[record.id]?.state = .cancelled
                        records[record.id]?.error = "The previous agent run ended before this interface finished. Ask the agent to refresh it."
                    }
                } catch {
                    eventErrors[record.eventID] = "Unable to restore interface: \(error.localizedDescription)"
                }
            }
        }
        // Seed stream cursors without replaying canonical state or overwriting local input.
        for event in session.events where event.message?.role == .assistant {
            let text = event.message?.segments.filter { $0.kind == .text }.compactMap(\.text).joined() ?? ""
            var stream = EditorAgentA2UIStream()
            let frames = stream.append(text) + stream.finish()
            streams[event.id] = stream
            sourceTexts[event.id] = text
            displayTexts[event.id] = stream.displayText
            if session.a2uiSurfaces == nil {
                currentEventID = event.id
                restoring = false
                consume(frames)
                restoring = true
            }
        }
        restoring = false
        currentEventID = ""
        touched.removeAll()
        if session.a2uiSurfaces == nil {
            for id in records.keys { records[id]?.state = .ready }
        }
    }

    var persistedRecords: [EditorAgentA2UISurfaceRecord] { records.values.sorted { $0.id < $1.id } }

    func beginRun(agentIdentity: String?) {
        self.agentIdentity = agentIdentity
        touched.removeAll()
    }

    func receive(_ event: EditorAgentEvent) {
        guard let message = event.message, message.role == .assistant else {
            return
        }
        let text = message.segments.filter { $0.kind == .text }.compactMap(\.text).joined()
        var stream = streams[event.id] ?? EditorAgentA2UIStream()
        var previous = sourceTexts[event.id] ?? ""
        // Reducer supplies the complete message. Consume only its newly appended suffix.
        if !text.hasPrefix(previous) {
            if stream.didPresentUI {
                eventErrors[event.id] = "The agent replaced an already streamed interface. Ask it to create a new surface."
                return
            }
            stream = EditorAgentA2UIStream()
            previous = ""
        }
        let suffix = String(text.dropFirst(previous.count))
        currentEventID = event.id
        consume(stream.append(suffix))
        streams[event.id] = stream
        sourceTexts[event.id] = text
        displayTexts[event.id] = stream.displayText
        currentEventID = ""
    }

    func finishRun(cancelled: Bool, failed: Bool = false, submission: EditorAgentA2UISubmission? = nil) {
        for eventID in streams.keys.sorted() {
            currentEventID = eventID
            if var stream = streams[eventID] {
                consume(stream.finish())
                streams[eventID] = stream
                displayTexts[eventID] = stream.displayText
            }
        }
        for surfaceID in touched {
            records[surfaceID]?.state = cancelled ? .cancelled : failed ? .failed : .ready
            if cancelled { records[surfaceID]?.error = "Agent run interrupted. Ask the agent to refresh this interface." }
        }
        if let submission, records[submission.surfaceID] != nil, !touched.contains(submission.surfaceID) {
            records[submission.surfaceID]?.state = cancelled ? .cancelled : failed ? .ready : .submitted
        }
        currentEventID = ""
        publish()
    }

    func surfaceIDs(for eventID: String) -> [String] {
        records.values.filter { $0.eventID == eventID }.map(\.id).sorted()
    }

    func rejectSubmission(_ message: String, surfaceID: String) {
        records[surfaceID]?.state = .ready
        setError(message, surfaceID: surfaceID)
    }

    func setError(_ message: String, surfaceID: String) {
        records[surfaceID]?.error = message
        publish()
    }

    private func consume(_ frames: [Result<Data, A2UIValidationError>]) {
        for frame in frames {
            do { try client.receive(frame.get()) } catch {
                eventErrors[currentEventID] = error.localizedDescription
                // Protocol errors are also retained for the next prompt's correction context.
            }
        }
    }

    private func surfaceChanged(_ surfaceID: String) {
        guard !restoring else {
            return
        }
        guard let surface = client.surfaces[surfaceID] else {
            records.removeValue(forKey: surfaceID)
            publish()
            return
        }
        var record = records[surfaceID] ?? .init(id: surfaceID, eventID: currentEventID, agentIdentity: agentIdentity, messages: [])
        record.messages = surface.restorationMessages()
        record.error = nil
        if !currentEventID.isEmpty {
            touched.insert(surfaceID)
            if record.state != .submitting { record.state = .receiving }
        }
        records[surfaceID] = record
        publish()
    }

    private func receiveClientEvent(_ event: A2UIClientEvent) {
        guard !restoring, case let .object(envelope) = event.envelope else {
            return
        }
        if case let .object(action) = envelope["action"], let surfaceID = action["surfaceId"]?.string,
           var record = records[surfaceID], record.state == .ready {
            record.state = .submitting
            record.error = nil
            records[surfaceID] = record
            publish()
            onSubmission?(.init(sessionID: id, surfaceID: surfaceID, agentIdentity: record.agentIdentity, event: event))
        } else if case let .object(error) = envelope["error"], let surfaceID = error["surfaceId"]?.string, records[surfaceID] != nil {
            records[surfaceID]?.error = error["message"]?.string
        }
    }

    private func publish() { onRecordsChanged?(persistedRecords) }
}

@MainActor @Observable
final class EditorAgentA2UIController {
    private(set) var sessions: [String: EditorAgentA2UISession] = [:]
    @ObservationIgnored var onRecordsChanged: ((String, [EditorAgentA2UISurfaceRecord]) -> Void)?
    @ObservationIgnored var onSubmission: ((EditorAgentA2UISubmission) -> Void)?

    @discardableResult
    func restoreIfNeeded(_ session: EditorAgentSession) -> EditorAgentA2UISession {
        if let existing = sessions[session.id] {
            return existing
        }
        let ui = EditorAgentA2UISession(session: session)
        ui.onRecordsChanged = { [weak self] records in self?.onRecordsChanged?(session.id, records) }
        ui.onSubmission = { [weak self] submission in self?.onSubmission?(submission) }
        sessions[session.id] = ui
        return ui
    }

    func remove(sessionID: String) {
        let session = sessions.removeValue(forKey: sessionID)
        session?.onSubmission = nil
        session?.onRecordsChanged = nil
    }
}
