@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorSceneDocumentEditor: View {
    static let hierarchyWidth: Float = 220

    let document: EditorSceneDocument
    let workbench: EditorWorkbenchViewModel
    let resourceRootURL: URL?
    let uiCatalog: UICatalog
    let inspectorViewModel: EditorInspectorSidebarViewModel
    let playModeState: EditorPlayModeState
    let playRuntime: EditorScenePlayRuntime?
    let onEntitySelected: (() -> Void)?
    let onPlay: (() -> Void)?
    let onStop: (() -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            sceneHierarchy
                .frame(width: Self.hierarchyWidth)
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier("AdaEditor.SceneEditor.HierarchyPanel")
            RectangleShape()
                .fill(theme.editorColors.border.opacity(0.5))
                .frame(width: 1)
            EditorSceneViewportView(
                document: document,
                resourceRootURL: resourceRootURL,
                uiCatalog: uiCatalog,
                inspectorViewModel: inspectorViewModel,
                playModeState: playModeState,
                playRuntime: playRuntime,
                onEntitySelected: onEntitySelected,
                onPlay: onPlay,
                onStop: onStop,
                onDocumentChanged: { workbench.replaceSceneDocument($0) }
            )
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .accessibilityIdentifier("AdaEditor.SceneEditor.ViewportPanel")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("AdaEditor.SceneEditor")
    }

    private var sceneHierarchy: some View {
        EditorSceneHierarchySidebar(
            document: document,
            presentation: .embedded,
            onSelectEntity: { entityID in
                workbench.selectSceneEntity(documentID: document.id, entityID: entityID)
                onEntitySelected?()
            },
            onToggleEntityExpanded: { entityID in
                workbench.toggleSceneEntityExpanded(documentID: document.id, entityID: entityID)
            },
            onAddEntity: { parentID in
                workbench.presentEntityPicker(documentID: document.id, parentID: parentID)
            },
            onSetEntityEnabled: { entityID, isEnabled in
                workbench.setSceneEntityEnabled(documentID: document.id, entityID: entityID, isEnabled: isEnabled)
            },
            onRenameEntity: { entityID, name in
                workbench.renameSceneEntity(documentID: document.id, entityID: entityID, name: name)
            },
            onDeleteEntity: { entityID in
                workbench.deleteSceneEntity(documentID: document.id, entityID: entityID)
            },
            onDuplicateEntity: { entityID in
                workbench.duplicateSceneEntity(documentID: document.id, entityID: entityID)
            },
            onCopyEntity: { entityID in
                workbench.copySceneEntity(documentID: document.id, entityID: entityID)
            },
            onPasteEntity: { parentID in
                workbench.pasteSceneEntity(documentID: document.id, parentID: parentID)
            },
            onReparentEntity: { entityID, parentID in
                workbench.reparentSceneEntity(documentID: document.id, entityID: entityID, parentID: parentID)
            }
        )
    }
}
