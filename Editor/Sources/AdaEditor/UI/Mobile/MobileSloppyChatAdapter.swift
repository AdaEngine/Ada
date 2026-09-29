#if os(iOS)
import Foundation
import Protocols
import SloppyRuntime

enum MobileSloppyChatAdapter {
    static func events(from sessionEvents: [AgentSessionEvent]) -> [EditorAgentEvent] {
        sessionEvents.sorted { $0.createdAt < $1.createdAt }.compactMap { event in
            if let call = event.toolCall {
                return EditorAgentEvent(id: event.id, kind: .runStatus, createdAt: event.createdAt, title: "Using \(call.tool)")
            }
            if let result = event.toolResult {
                return EditorAgentEvent(
                    id: event.id, kind: .runStatus, createdAt: event.createdAt,
                    title: "\(result.tool) \(result.ok ? "completed" : "failed")", isSuccessful: result.ok
                )
            }
            guard let message = event.message, message.role != .system else { return nil }
            if message.segments.allSatisfy({ $0.kind == .thinking }) {
                return EditorAgentEvent(id: event.id, kind: .runStatus, createdAt: event.createdAt, title: "Thinking")
            }
            let text = message.segments.filter { $0.kind == .text }.compactMap(\.text).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return EditorAgentEvent(
                id: event.id, kind: .message, createdAt: event.createdAt,
                message: EditorAgentMessage(
                    id: message.id, role: message.role == .user ? .user : .assistant,
                    segments: [.init(kind: .text, text: text)], createdAt: message.createdAt
                )
            )
        }
    }

    @MainActor
    static func record(_ activity: SloppyAgentActivity, for id: UUID, in state: MobileEditorChatState) {
        switch activity {
        case .thinking:
            state.setStatus("Thinking…", for: id)
            if state.events(for: id).last?.title != "Thinking" {
                state.record(EditorAgentEvent(kind: .runStatus, title: "Thinking"), for: id)
            }
        case .toolStarted(let tool):
            state.setStatus(tool == "editor.build" ? "Building the project…" : "Using \(tool)…", for: id)
            let callID = UUID().uuidString
            state.record(EditorAgentEvent(
                id: callID, kind: .toolCall,
                toolCall: EditorAgentToolCall(id: callID, title: tool, kind: "tool", status: .inProgress, content: [], locations: [])
            ), for: id)
        case .toolFinished(let tool, let succeeded):
            if var event = state.events(for: id).last(where: { $0.toolCall?.title == tool && $0.toolCall?.status == .inProgress }) {
                event.toolCall?.status = succeeded ? .completed : .failed
                event.isSuccessful = succeeded
                state.record(event, for: id)
            }
            state.setStatus(succeeded ? "Agent is working…" : "\(tool) failed; checking the result…", for: id)
        }
    }

    static func events(from messages: [SloppyChatMessage]) -> [EditorAgentEvent] {
        messages.map { message in
            EditorAgentEvent(
                id: message.id,
                kind: .message,
                createdAt: message.createdAt,
                message: EditorAgentMessage(
                    id: message.id,
                    role: message.role == .user ? .user : .assistant,
                    segments: [EditorAgentMessageSegment(kind: .text, text: message.text)],
                    createdAt: message.createdAt
                )
            )
        }
    }
}
#endif
