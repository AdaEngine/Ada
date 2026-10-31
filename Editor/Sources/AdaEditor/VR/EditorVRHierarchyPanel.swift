import AdaEngine

/// Existing hierarchy UI and workbench actions are reused without a SwiftUI rewrite.
struct EditorVRHierarchyPanel: View {
    let workspace: EditorVRWorkspace
    var body: some View {
        EditorSceneHierarchySidebar(
            document: workspace.document,
            showsHeader: false,
            touchSelection: true,
            onSelectEntity: workspace.select,
            onToggleEntityExpanded: { id in perform { document in workspace.workbench.toggleSceneEntityExpanded(documentID: document.id, entityID: id) } },
            onAddEntity: { parent in perform { document in workspace.workbench.addSceneEntity(documentID: document.id, parentID: parent, template: .model3D) } },
            onAddGroup: { parent in perform { document in workspace.workbench.addSceneGroup(documentID: document.id, parentID: parent) } },
            onSetEntityEnabled: { id, enabled in perform { document in workspace.workbench.setSceneEntityEnabled(documentID: document.id, entityID: id, isEnabled: enabled) } },
            onRenameEntity: { id, name in perform { document in workspace.workbench.renameSceneEntity(documentID: document.id, entityID: id, name: name) } },
            onDeleteEntity: { id in perform { document in workspace.workbench.deleteSceneEntity(documentID: document.id, entityID: id) } },
            onDuplicateEntity: { id in perform { document in workspace.workbench.duplicateSceneEntity(documentID: document.id, entityID: id) } },
            onCopyEntity: { id in perform { document in workspace.workbench.copySceneEntity(documentID: document.id, entityID: id) } },
            onPasteEntity: { parent in perform { document in _ = workspace.workbench.pasteSceneEntity(documentID: document.id, parentID: parent) } },
            onReparentEntity: { id, parent in perform { document in workspace.workbench.reparentSceneEntity(documentID: document.id, entityID: id, parentID: parent) } }
        ).disabled(workspace.isManipulating)
    }
    private func perform(_ action: @escaping (EditorSceneDocument) -> Void) {
        workspace.edit { if let document = workspace.document { action(document) } }
    }
}
