#if os(iOS)
@_spi(AdaEngine) import AdaEngine
import Foundation

struct MobileEditorSceneEditor: View {
    @Environment(\.theme) private var theme

    let document: EditorSceneDocument
    let projectRootURL: URL

    @State private var workbench: EditorWorkbenchViewModel
    @State private var inspectorViewModel = EditorInspectorSidebarViewModel()

    init(document: EditorSceneDocument, projectRootURL: URL) {
        self.document = document
        self.projectRootURL = projectRootURL
        self._workbench = State(initialValue: EditorWorkbenchViewModel(
            openDocuments: [.scene(document)],
            activeDocumentID: document.id
        ))
    }

    private var currentDocument: EditorSceneDocument {
        workbench.sceneDocument(id: document.id) ?? document
    }

    var body: some View {
        GeometryReader { geometry in
            let usableHeight = max(0, geometry.size.height)
            let viewportHeight = max(220, usableHeight * 0.65)

            VStack(spacing: 0) {
                EditorSceneViewportView(
                    document: currentDocument,
                    resourceRootURL: EditorViewModel.assetsDirectoryURL(for: projectRootURL, fileManager: .default),
                    inspectorViewModel: inspectorViewModel,
                    playModeState: .editing,
                    playRuntime: nil,
                    onEntitySelected: nil,
                    onPlay: nil,
                    onStop: nil,
                    onDocumentChanged: { workbench.replaceSceneDocument($0) }
                )
                .frame(height: viewportHeight)
                .accessibilityIdentifier("AdaEditor.Mobile.Scene.Viewport")

                EditorSceneHierarchySidebar(
                    document: currentDocument,
                    presentation: .embedded,
                    onSelectEntity: { workbench.selectSceneEntity(documentID: document.id, entityID: $0) },
                    onToggleEntityExpanded: { workbench.toggleSceneEntityExpanded(documentID: document.id, entityID: $0) },
                    onAddEntity: { workbench.addSceneEntity(documentID: document.id, parentID: $0) },
                    onSetEntityEnabled: { workbench.setSceneEntityEnabled(documentID: document.id, entityID: $0, isEnabled: $1) },
                    onRenameEntity: { workbench.renameSceneEntity(documentID: document.id, entityID: $0, name: $1) },
                    onDeleteEntity: { workbench.deleteSceneEntity(documentID: document.id, entityID: $0) },
                    onDuplicateEntity: { workbench.duplicateSceneEntity(documentID: document.id, entityID: $0) },
                    onCopyEntity: { workbench.copySceneEntity(documentID: document.id, entityID: $0) },
                    onPasteEntity: { workbench.pasteSceneEntity(documentID: document.id, parentID: $0) },
                    onReparentEntity: { workbench.reparentSceneEntity(documentID: document.id, entityID: $0, parentID: $1) }
                )
                .frame(height: max(100, usableHeight - viewportHeight))
                .accessibilityIdentifier("AdaEditor.Mobile.Scene.Hierarchy")
            }
            .frame(width: geometry.size.width, height: usableHeight, alignment: .top)
        }
        .background(theme.editorColors.background)
        .onAppear {
            workbench.setDocumentEditedHandler { [weak workbench] documentID in
                _ = workbench?.saveSceneDocument(id: documentID)
            }
        }
        .accessibilityIdentifier("AdaEditor.Mobile.Scene.Editor")
    }
}
#endif
