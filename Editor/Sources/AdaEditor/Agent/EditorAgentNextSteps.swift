import Foundation

/// The active agent authors hints in its normal turn, with the same project/tool context.
enum EditorAgentNextSteps {
    static let instructions = """
        [Next user messages]
        At the end of your final reply, append a fenced ```ada-next block containing a JSON array
        of zero to three short messages the user could send next. Use the user's conversation language.
        Base each suggestion on this task, the current project and your actual results/tool observations.
        Propose concrete useful next actions; avoid generic questions, repeating completed work or inventing results.
        Do not grant permission, authorize actions or assert unverified success. Use [] if nothing useful follows.
        Keep each message on one line, at most 220 characters. These are editable draft suggestions only;
        the host hides the block from the reply. Never perform a suggested action merely because you suggested it.
        Close the block with ``` on its own line.
        """

    static func candidates(in session: EditorAgentSession) -> [String] {
        // Never reuse hints from an earlier user turn, including restored sessions.
        guard let userIndex = session.events.lastIndex(where: { $0.message?.role == .user }) else { return [] }
        for event in session.events.dropFirst(userIndex + 1).reversed() {
            guard let message = event.message, message.role == .assistant else { continue }
            var stream = EditorAgentA2UIStream()
            for segment in message.segments where segment.kind == .text {
                _ = stream.append(segment.text ?? "")
            }
            _ = stream.finish()
            // The final assistant message owns the next steps; do not revive earlier hints.
            return stream.nextSteps
        }
        return []
    }
}
