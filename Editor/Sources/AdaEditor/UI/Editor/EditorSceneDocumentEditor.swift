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
    var onTerrainToolSelected: (() -> Void)? = nil
    let onPlay: (() -> Void)?
    let onStop: (() -> Void)?
    var annotationAgent: EditorAgentViewModel?
    var onAnnotationAdded: (() -> Void)?
    var isActive = true

    @Environment(\.theme) private var theme
    @State private var preferredHierarchyWidth: Float = {
        let saved = UserDefaults.standard.float(forKey: "AdaEditor.SceneHierarchy.Width")
        return saved > 0 ? saved : Self.hierarchyWidth
    }()
    @State private var hierarchyDragStart: Float?

    var body: some View {
        if document.isLoading {
            Text(L10n.text("Loading scene resources…"))
                .foregroundColor(theme.editorColors.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("AdaEditor.SceneDocument.Loading")
        } else {
            loadedScene
        }
    }

    private var loadedScene: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sceneHierarchy
                    .frame(width: EditorSceneHierarchyLayout.width(preferredHierarchyWidth, available: geometry.size.width))
                    .frame(maxHeight: .infinity)
                    .accessibilityIdentifier("AdaEditor.SceneEditor.HierarchyPanel")
                ZStack {
                    RectangleShape().fill(theme.editorColors.border.opacity(0.5)).frame(width: 1)
                    EditorResizeHandle(
                        axis: .horizontal,
                        onResize: { translation in
                            let start = hierarchyDragStart ?? EditorSceneHierarchyLayout.width(preferredHierarchyWidth, available: geometry.size.width)
                            hierarchyDragStart = start
                            preferredHierarchyWidth = EditorSceneHierarchyLayout.width(start + translation.width, available: geometry.size.width)
                        },
                        onResizeEnded: {
                            hierarchyDragStart = nil
                            UserDefaults.standard.set(preferredHierarchyWidth, forKey: "AdaEditor.SceneHierarchy.Width")
                        #if os(Windows)
                            // The native event loop does not flush Foundation preferences on exit.
                            UserDefaults.standard.synchronize()
                        #endif
                        })
                }
                .frame(width: 8)
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier("AdaEditor.SceneEditor.HierarchyResize")
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
                    onDocumentChanged: { workbench.replaceSceneDocument($0) },
                    onTerrainToolSelected: onTerrainToolSelected,
                    annotationAgent: annotationAgent,
                    onAnnotationAdded: onAnnotationAdded,
                    isDocumentActive: isActive
                )
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .accessibilityIdentifier("AdaEditor.SceneEditor.ViewportPanel")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("AdaEditor.SceneEditor")
        }
    }

    private var sceneHierarchy: some View {
        EditorSceneHierarchySidebar(
            document: isActive ? document : nil,
            presentation: .embedded,
            onSelectEntity: { entityID in
                if let annotationAgent, annotationAgent.sceneAnnotations.isSelecting,
                   let context = EditorAgentSceneContext(document: document, entityID: entityID) {
                    annotationAgent.sceneAnnotations.select(context)
                } else {
                    workbench.selectSceneEntity(documentID: document.id, entityID: entityID)
                    onEntitySelected?()
                }
            },
            onToggleEntityExpanded: { entityID in
                workbench.toggleSceneEntityExpanded(documentID: document.id, entityID: entityID)
            },
            onAddEntity: { parentID in
                workbench.presentEntityPicker(documentID: document.id, parentID: parentID)
            },
            onAddGroup: { parentID in
                workbench.addSceneGroup(documentID: document.id, parentID: parentID)
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

enum EditorSceneHierarchyLayout {
    static func width(_ preferred: Float, available: Float) -> Float {
        let maximum = max(0, min(520, available - 248))
        return min(max(preferred, min(180, maximum)), maximum)
    }
}
