#if os(iOS)
import SloppyRuntime

enum MobileSloppyChatAdapter {
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
