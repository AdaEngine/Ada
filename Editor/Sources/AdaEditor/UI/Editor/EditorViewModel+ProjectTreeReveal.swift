extension EditorViewModel {
    var canRevealActiveDocumentInProjectTree: Bool {
        guard let path = workbench.activeDocumentRelativePath else {
            return false
        }
        return projectSidebar.items.contains { !$0.isFolder && $0.relativePath == path }
    }

    func revealActiveDocumentInProjectTree() {
        guard let path = workbench.activeDocumentRelativePath,
              projectSidebar.revealFile(relativePath: path) else { return }
        toolStrip.activeLeftTopTool = "fileTree"
        showLeftPanel = true
    }
}
