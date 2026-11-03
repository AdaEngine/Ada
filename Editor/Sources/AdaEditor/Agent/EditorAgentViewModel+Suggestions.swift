@_spi(AdaEngine) import AdaEngine
import Foundation

extension EditorAgentViewModel {
    func refreshPromptSuggestions() {
        guard isPanelVisible, !isSending, !isConnectingCatalogAgent, let session = activeSession else {
            promptSuggestions.update(nil)
            return
        }
        var messages: [EditorAgentSuggestionMessage] = []
        for event in session.events.reversed() {
            guard let message = event.message, message.role == .user || message.role == .assistant else { continue }
            var text = ""
            for segment in message.segments where segment.kind == .text {
                guard let segmentText = segment.text, text.count < 1_200 else { continue }
                if !text.isEmpty { text.append("\n") }
                text.append(contentsOf: segmentText.prefix(1_200 - text.count))
            }
            guard !text.isEmpty else { continue }
            messages.append(.init(role: message.role, text: text))
            if messages.count == 6 { break }
        }
        messages.reverse()
        let completedReplyID = !prompt.isEmpty || unpersistedSuggestionSessions.contains(session.id) ? nil : Self.completedSuggestionReply(in: session)
        let context = EditorAgentPromptSuggestions.Context(
            sessionID: session.id,
            draft: prompt,
            caretOffset: promptCaretOffset ?? prompt.count,
            mode: mode.rawValue,
            languageCode: EditorLocalization.shared.language.rawValue,
            messages: messages,
            followUps: completedReplyID == nil ? [] : EditorAgentNextSteps.candidates(in: session),
            completedReplyID: completedReplyID
        )
        promptSuggestions.update(.init(
            context: context,
            isVisible: isPanelVisible,
            isSending: isSending || isConnectingCatalogAgent,
            hasStructuredCompletion: EditorAgentCompletionToken.current(in: prompt, cursorOffset: promptCaretOffset) != nil
        ))
    }

    func dismissPromptSuggestions() {
        refreshPromptSuggestions()
        promptSuggestions.dismiss()
    }

    func insertPromptSuggestion(_ text: String) {
        refreshPromptSuggestions()
        guard promptSuggestions.canInsert(text) else { return }
        prompt = text
        promptCaretOffset = text.count
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let position = TextEditorSourcePosition(line: lines.count - 1, column: lines.last?.count ?? 0)
        promptCompletionFocus = TextEditorSourceRange(start: position, end: position)
        // Suppress the newly accepted draft too, until the author edits or changes context.
        promptSuggestions.dismiss()
        Task { @MainActor [weak self] in self?.focusCompletionPrompt() }
    }

    /// Only persisted terminal evidence enables next-turn hints, including restored sessions.
    static func completedSuggestionReply(in session: EditorAgentSession) -> String? {
        guard let userIndex = session.events.lastIndex(where: { $0.message?.role == .user }),
              let terminalIndex = session.events.lastIndex(where: { $0.kind == .runStatus || $0.kind == .error }),
              terminalIndex > userIndex else { return nil }
        let terminal = session.events[terminalIndex]
        guard terminal.kind == .runStatus, terminal.title == "Done", terminal.isSuccessful != false,
              terminal.details?.lowercased() != "cancelled" else { return nil }
        let turn = session.events[(userIndex + 1)..<terminalIndex]
        guard turn.contains(where: { event in
                  event.message?.role == .assistant && event.message?.segments.contains(where: {
                      $0.kind == .text && !($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) == true
              }) else { return nil }
        return terminal.id
    }
}
