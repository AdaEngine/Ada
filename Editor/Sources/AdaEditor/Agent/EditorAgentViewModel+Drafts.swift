extension EditorAgentViewModel {
    struct SessionDraft {
        var prompt: String
        var attachments: [EditorAgentAttachment]
        var codeSelection: EditorAgentCodeSelectionContext?
        var mode: EditorAgentChatMode
    }

    func rememberSessionDraft() {
        guard let id = activeSession?.id else {
            return
        }
        sessionDrafts[id] = SessionDraft(prompt: prompt, attachments: pendingAttachments, codeSelection: codeSelection, mode: mode)
    }

    func restoreSessionDraft() {
        let draft = activeSession.flatMap { sessionDrafts[$0.id] }
        promptBinding.wrappedValue = draft?.prompt ?? ""
        pendingAttachments = draft?.attachments ?? []
        codeSelection = draft?.codeSelection
        mode = draft?.mode ?? .build
    }
}
