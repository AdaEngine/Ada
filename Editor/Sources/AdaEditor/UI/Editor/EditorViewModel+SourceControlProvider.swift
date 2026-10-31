import Foundation

extension EditorViewModel {
    func selectSourceControlProvider(_ provider: EditorSourceControlProvider) {
        guard provider != sourceControl.provider, !sourceControl.isRunning, provider.isAvailable, let projectURL else { return }
        do {
            try provider.save(in: projectURL)
        } catch {
            sourceControl.commandError = L10n.text("Could not save the source control choice: \(error.localizedDescription)")
            return
        }
        sourceControl.refreshTask?.cancel()
        sourceControl.historyTask?.cancel()
        sourceControl.refreshGeneration = UUID()
        sourceControl.historyGeneration = UUID()
        // Review documents own their service; close them before changing providers
        // so an old Stage callback can never write through the new service.
        for document in sourceControl.documents.values {
            document.invalidate()
            document.isOpen = false
            workbench.closeDocument(id: document.id)
        }
        sourceControl.documents = [:]
        sourceControl.provider = provider
        sourceControlService = provider.makeService()
        sourceControl.snapshot = .empty
        sourceControl.snapshot.provider = provider
        sourceControl.commits = []
        sourceControl.historyHead = nil
        sourceControl.hasMoreHistory = false
        sourceControl.isLoadingHistory = false
        sourceControl.historyError = nil
        sourceControl.commandError = nil
        sourceControl.isRefreshing = false
        footer.setSourceControlFooterTitle(nil)
        refreshSourceControl()
    }
}
