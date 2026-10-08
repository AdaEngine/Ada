import Foundation

enum MobileEditorVoiceContent {
    /// Only an answer following the current user turn can be spoken.
    static func reply(in events: [EditorAgentEvent]) -> String? {
        guard let userIndex = events.lastIndex(where: { $0.message?.role == .user }) else {
            return nil
        }
        let response = events.dropFirst(userIndex + 1).last { $0.message?.role == .assistant }
        let text = response?.message?.segments.filter { $0.kind == .text }.compactMap(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}
