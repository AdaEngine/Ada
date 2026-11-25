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
    var trackedScenePlay: EditorTrackedScenePlay?
    let playRuntime: EditorScenePlayRuntime?
    let onEntitySelected: (() -> Void)?
    var onSceneInspectorRequested: (() -> Void)?
    let onPlay: (() -> Void)?
    let onStop: (() -> Void)?
    var annotationAgent: EditorAgentViewModel?
    var onAnnotationAdded: (() -> Void)?
    var isActive = true

    private var compact: Bool { AdaEngineStyleLayoutSpec.usesCompactWorkspace }
    @State private var preferredHierarchyWidth: Float = {
        let saved = UserDefaults.standard.float(forKey: "AdaEditor.SceneHierarchy.Width")
        return saved > 0 ? saved : Self.hierarchyWidth
    }()
    @State private var hierarchyDragStart: Float?

    var body: some View {
        if document.isLoading {
            EditorSceneLoadingProgressView(progress: .init(phase: .document))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("AdaEditor.SceneDocument.Loading")
        } else {
            loadedScene
        }
    }

    private var loadedScene: some View {
        GeometryReader { geometry in
            let hierarchyWidth = EditorSceneHierarchyLayout.width(preferredHierarchyWidth, available: geometry.size.width)
            HStack(spacing: compact && hierarchyWidth > 0 ? AdaEngineStyleLayoutSpec.workspaceDividerSize : 0) {
                sceneHierarchy(width: hierarchyWidth)
                    .frame(width: hierarchyWidth)
                    .frame(maxHeight: .infinity)
                    .accessibilityIdentifier("AdaEditor.SceneEditor.HierarchyPanel")
                if !compact {
                    hierarchyDivider(availableWidth: geometry.size.width)
                }
                EditorSceneViewportView(
                    document: document,
                    resourceRootURL: resourceRootURL,
                    uiCatalog: uiCatalog,
                    inspectorViewModel: inspectorViewModel,
                    playModeState: playModeState,
                    trackedScenePlay: trackedScenePlay,
                    playRuntime: playRuntime,
                    onEntitySelected: onEntitySelected,
                    onPlay: onPlay,
                    onStop: onStop,
                    onDocumentChanged: { workbench.applySceneViewportEdit($0) },
                    onSceneInspectorRequested: onSceneInspectorRequested,
                    annotationAgent: annotationAgent,
                    onAnnotationAdded: onAnnotationAdded,
                    isDocumentActive: isActive
                )
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .accessibilityIdentifier("AdaEditor.SceneEditor.ViewportPanel")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(anchor: .topLeading) {
                if compact && hierarchyWidth > 0 {
                    let overlap = (AdaEngineStyleLayoutSpec.dividerHitSize - AdaEngineStyleLayoutSpec.workspaceDividerSize) / 2
                    hierarchyDivider(availableWidth: geometry.size.width)
                        .offset(x: hierarchyWidth - overlap)
                }
            }
            .accessibilityIdentifier("AdaEditor.SceneEditor")
        }
    }

    private func hierarchyDivider(availableWidth: Float) -> some View {
        EditorResizeHandle(
            axis: .horizontal,
            onResize: { translation in
                let start = hierarchyDragStart ?? EditorSceneHierarchyLayout.width(preferredHierarchyWidth, available: availableWidth)
                hierarchyDragStart = start
                preferredHierarchyWidth = EditorSceneHierarchyLayout.width(start + translation.width, available: availableWidth)
            },
            onResizeEnded: {
                hierarchyDragStart = nil
                UserDefaults.standard.set(preferredHierarchyWidth, forKey: "AdaEditor.SceneHierarchy.Width")
            #if os(Windows)
                // The native event loop does not flush Foundation preferences on exit.
                UserDefaults.standard.synchronize()
            #endif
            },
            showsDivider: true
        )
        .accessibilityIdentifier("AdaEditor.SceneEditor.HierarchyResize")
    }

    private func sceneHierarchy(width: Float) -> some View {
        EditorSceneHierarchySidebar(
            document: isActive ? document : nil,
            presentation: .embedded,
            showsGroupShortcut: !compact || width >= 170,
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
