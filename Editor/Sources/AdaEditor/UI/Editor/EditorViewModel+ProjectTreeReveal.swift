extension EditorViewModel {
    var canRevealActiveDocumentInProjectTree: Bool {
        guard let path = workbench.activeDocument?.relativePath else { return false }
        return projectSidebar.items.contains { !$0.isFolder && $0.relativePath == path }
    }

    func revealActiveDocumentInProjectTree() {
        guard let path = workbench.activeDocument?.relativePath,
              projectSidebar.revealFile(relativePath: path) else { return }
        toolStrip.activeLeftTopTool = "fileTree"
        showLeftPanel = true
    }
}
