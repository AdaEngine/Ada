extension EditorWorkbenchViewModel {
    /// Retain at most the last scene in each pane; closing or moving its tab
    /// removes it from that pane's presentation without retaining its world.
    func retainedSceneDocument(in pane: EditorWorkbenchPane) -> EditorSceneDocument? {
        if case let .scene(scene)? = selectedDocument(in: pane) { return scene }
        guard let id = retainedSceneDocumentIDs[pane], self.pane(for: id) == pane else { return nil }
        return sceneDocument(id: id)
    }

    func rememberScenePresentation(in pane: EditorWorkbenchPane) {
        guard case let .scene(scene)? = selectedDocument(in: pane), retainedSceneDocumentIDs[pane] != scene.id else { return }
        retainedSceneDocumentIDs[pane] = scene.id
    }

    func clearRetainedScenePresentations() {
        if !retainedSceneDocumentIDs.isEmpty { retainedSceneDocumentIDs.removeAll() }
    }
}
