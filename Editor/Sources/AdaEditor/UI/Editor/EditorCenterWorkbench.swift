@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorCenterWorkbench: View {
    let viewModel: EditorWorkbenchViewModel
    let inspectorViewModel: EditorInspectorSidebarViewModel
    let playModeState: EditorPlayModeState
    let scenePlayRuntime: EditorScenePlayRuntime?
    let sceneResourceRootURL: URL?
    let onPlayScene: (() -> Void)?
    let onStopScene: (() -> Void)?
    let onSceneEntitySelected: (() -> Void)?
    var onTerrainToolSelected: (() -> Void)? = nil
    let onSourceHover: ((EditorTextDocument, EditorSourceLocation?) -> Void)?
    let onGoToDefinition: ((EditorTextDocument, EditorSourceLocation) -> Void)?
    let onCompletionPosition: ((EditorTextDocument, EditorSourceLocation, String) -> Void)?
    let onCompletionRequest: ((EditorTextDocument, EditorSourceLocation, String) -> Void)?
    let onApplyCompletion: ((EditorCompletionItem, EditorTextDocument) -> Void)?
    let onMoveCompletionSelection: ((EditorTextDocument, Int) -> Bool)?
    let onAcceptCompletion: ((EditorTextDocument) -> Bool)?
    var onAcceptSnippetPlaceholder: ((EditorTextDocument, EditorSourceRange?) -> Bool)? = nil
    let onTextSelection: ((EditorTextDocument, EditorSourceRange?, String?) -> Void)?
    let onChatSelection: ((EditorTextDocument, EditorSourceRange, String) -> Void)?
    let sourceContextMenuItems: ((EditorTextDocument, EditorSourceLocation) -> [TextEditorContextMenuItem])?
    let onSelectDocument: ((String) -> Void)?
    let onRevealDocument: ((EditorWorkbenchDocument) -> Void)?
    let onCopyDocumentPath: ((EditorWorkbenchDocument, Bool) -> Void)?
    let onSelectPreview: ((EditorPreviewDeclaration) -> Void)?
    let onRebuildPreview: (() -> Void)?
    let onHidePreview: (() -> Void)?
    let onShowPreviewBuildOutput: (() -> Void)?
    var debugger: EditorDebugger?
    var showsDocumentTabs = true
    var projectItems: [EditorProjectSidebarViewModel.Item] = []
    var onOpenProjectItem: ((EditorProjectSidebarViewModel.Item) -> Void)?

    @Environment(\.metrics) private var metrics
    @Environment(\.theme) private var theme

    @State private var previewResizeState = EditorPreviewResizeState()
    @State private var draggedTabID: String?
    @State private var dropTargetTabID: String?
    private var filesBrowserPanes: Set<EditorWorkbenchPane> {
        get { viewModel.filesBrowserPanes }
        nonmutating set { viewModel.filesBrowserPanes = newValue }
    }
    @State private var splitResizeState = EditorWorkbenchResizeState()

    var body: some View {
        workbenchContent
            .background(
                RoundedRectangleShape(cornerRadius: metrics.panelsRoundedCorner)
                    .fill(theme.editorColors.surfaceElevated)
            )
            .mask(RoundedRectangleShape(cornerRadius: metrics.panelsRoundedCorner))
            .overlay {
                adaEditorPanelBorder(theme: theme, cornerRadius: metrics.panelsRoundedCorner)
            }
            .onChange(of: viewModel.activeDocumentID) { _, id in
                if !id.isEmpty {
                    filesBrowserPanes.remove(viewModel.pane(for: id))
                }
            }
    }
}

extension EditorCenterWorkbench {
    @ViewBuilder
    private var workbenchContent: some View {
        if viewModel.isSplit {
            GeometryReader { geometry in
                EditorWorkbenchPanelsLayout(state: splitResizeState) {
                    documentPane(.primary)
                    splitResizeHandle(availableWidth: geometry.size.width)
                    documentPane(.secondary)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        } else {
            documentPane(.primary)
        }
    }

    private func documentPane(_ pane: EditorWorkbenchPane) -> some View {
        VStack(spacing: 0) {
            if showsDocumentTabs {
                editorTabs(in: pane)
                    .frame(height: AdaEngineStyleLayoutSpec.editorTabHeight)
                    .overlay(anchor: .bottomLeading) {
                        RectangleShape()
                            .fill(viewModel.focusedPane == pane ? theme.editorColors.blue : theme.editorColors.border)
                            .frame(height: viewModel.isSplit ? 2 : 0)
                            .allowsHitTesting(false)
                    }
            }
            activeDocumentView(in: pane)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .layoutPriority(100)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .onPrimaryInteraction {
            guard let document = viewModel.selectedDocument(in: pane) else {
                viewModel.focusPane(pane)
                return
            }
            guard document.id != viewModel.activeDocumentID else {
                return
            }
            onSelectDocument?(document.id) ?? viewModel.selectDocument(id: document.id)
        }
        .accessibilityIdentifier("AdaEditor.Workbench.Pane.\(pane.rawValue)")
    }

    private func splitResizeHandle(availableWidth: Float) -> some View {
        ZStack {
            RectangleShape().fill(theme.editorColors.border).frame(width: 1)
            EditorResizeHandle(
                axis: .horizontal,
                onResize: { splitResizeState.resize(translation: $0.width, availableWidth: availableWidth) },
                onResizeEnded: { splitResizeState.endDrag() }
            )
        }
        .frame(width: EditorWorkbenchPanelsLayout.handleWidth)
        .frame(maxHeight: .infinity)
        .accessibilityIdentifier("AdaEditor.Workbench.Split.Resize")
    }

    private func editorTabs(in pane: EditorWorkbenchPane) -> some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    #if !os(macOS) && !os(Windows) && !os(Linux)
                        filesTab(in: pane)
                    #endif
                    ForEach(viewModel.documents(in: pane), id: \.id) { document in
                        editorTab(document, active: !filesBrowserPanes.contains(pane) && document.id == viewModel.selectedDocument(in: pane)?.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            if viewModel.isSplit {
                Button(L10n.text("Merge")) { viewModel.mergePanes() }
                    .buttonStyle(DefaultButtonStyle())
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
                    .padding(.horizontal, 8)
                    .accessibilityIdentifier("AdaEditor.Workbench.Split.Merge.\(pane.rawValue)")
            } else if let document = viewModel.selectedDocument(in: pane) {
                Button(action: { viewModel.splitDocument(id: document.id) }) {
                    Text("\u{E949}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 18))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(EditorChromeHoverButtonStyle(theme: theme))
                .foregroundColor(theme.editorColors.blue)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("AdaEditor.Workbench.Split")
            }
        }
        .background(theme.editorColors.surfaceElevated)
    }

    private func filesTab(in pane: EditorWorkbenchPane) -> some View {
        Button(action: { filesBrowserPanes.insert(pane) }) {
            HStack(spacing: 7) {
                Text("\u{E2C7}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 14))
                    .foregroundColor(theme.editorColors.blue)
                Text(L10n.text("Files"))
                    .font(.system(size: 12))
                    .foregroundColor(filesBrowserPanes.contains(pane) ? theme.editorColors.text : theme.editorColors.muted)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
        }
        .buttonStyle(DefaultButtonStyle())
        .background(
            RoundedRectangleShape(cornerRadius: 5)
                .fill(filesBrowserPanes.contains(pane) ? theme.editorColors.surface : theme.editorColors.surfaceElevated)
        )
        .overlay {
            RoundedRectangleShape(cornerRadius: 5)
                .stroke(
                    filesBrowserPanes.contains(pane) ? theme.editorColors.blue.opacity(0.72) : theme.editorColors.border.opacity(0.52),
                    lineWidth: 1
                )
        }
        .accessibilityIdentifier(pane == .primary ? "AdaEditor.Tab.Files" : "AdaEditor.Tab.Files.secondary")
    }

    private func editorTab(_ document: EditorWorkbenchDocument, active: Bool) -> some View {
        HStack(spacing: 0) {
            Button(action: {
                if draggedTabID == document.id {
                    draggedTabID = nil
                    return
                }
                filesBrowserPanes.remove(viewModel.pane(for: document.id))
                onSelectDocument?(document.id) ?? viewModel.selectDocument(id: document.id)
            }) {
                HStack(spacing: 7) {
                    if let language = textLanguage(for: document), let image = EditorLanguageLogo.image(for: language) {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                    } else {
                        Text(tabIcon(for: document))
                            .font(AdaEditorMaterialSymbolFont.font(size: 14))
                            .foregroundColor(tabIconColor(for: document))
                    }
                    Text(tabTitle(for: document))
                        .font(.system(size: 12))
                        .foregroundColor(active ? theme.editorColors.text : theme.editorColors.muted)
                        .lineLimit(1)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 26)
            }
            .buttonStyle(DefaultButtonStyle())
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 26, maxHeight: 26)
            .accessibilityIdentifier("AdaEditor.Tab.Select.\(document.id)")
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        draggedTabID = document.id
                        dropTargetTabID = tabDropTarget(for: document.id, translationX: value.translation.width)
                    }
                    .onEnded { value in
                        let targetID = tabDropTarget(for: document.id, translationX: value.translation.width)
                        dropTargetTabID = nil
                        // The button receives this same release after the gesture.
                        // Clear the drag flag on the next turn if its action was not invoked.
                        Task { @MainActor in
                            if draggedTabID == document.id {
                                draggedTabID = nil
                            }
                        }
                        guard
                            let targetID,
                            let targetIndex = viewModel.openDocuments.firstIndex(where: { $0.id == targetID })
                        else {
                            return
                        }
                        viewModel.moveDocument(id: document.id, toIndex: targetIndex)
                    }
            )

            Button(action: { viewModel.closeDocument(id: document.id) }) {
                Text("\u{E5CD}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 12))
                    .foregroundColor(active ? theme.editorColors.text.opacity(0.75) : theme.editorColors.muted.opacity(0.70))
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangleShape(cornerRadius: 4).fill(active ? theme.editorColors.surface.opacity(0.62) : Color.clear))
            }
            .buttonStyle(DefaultButtonStyle())
            .padding(.trailing, 6)
            .accessibilityIdentifier("AdaEditor.Tab.Close.\(document.id)")
        }
        .frame(width: editorTabWidth(document), height: 26)
        .background(RoundedRectangleShape(cornerRadius: 5).fill(active ? theme.editorColors.surface : theme.editorColors.surfaceElevated))
        .overlay {
            RoundedRectangleShape(cornerRadius: 5)
                .stroke(
                    dropTargetTabID == document.id ? theme.editorColors.blue : active ? theme.editorColors.blue.opacity(0.72) : theme.editorColors.border.opacity(0.52),
                    lineWidth: dropTargetTabID == document.id ? 2 : 1
                )
        }
        .opacity(draggedTabID == document.id ? 0.7 : 1)
        .onMiddleClick {
            viewModel.closeDocument(id: document.id)
        }
        .contextMenu {
            Button(viewModel.pane(for: document.id) == .secondary ? L10n.text("Move to Left Group") : L10n.text("Split Right")) {
                filesBrowserPanes.remove(.secondary)
                if viewModel.pane(for: document.id) == .secondary {
                    viewModel.moveDocument(id: document.id, to: .primary)
                } else {
                    viewModel.splitDocument(id: document.id)
                }
            }
            if viewModel.isSplit {
                Button(L10n.text("Merge Editor Groups")) { viewModel.mergePanes() }
            }
            Divider()
            Button(L10n.text("Close")) {
                viewModel.closeDocument(id: document.id)
            }
            if viewModel.documents(in: viewModel.pane(for: document.id)).count > 1 {
                Button(L10n.text("Close Others")) {
                    viewModel.closeOtherDocuments(keeping: document.id)
                }
            }
            if let index = viewModel.documents(in: viewModel.pane(for: document.id)).firstIndex(where: { $0.id == document.id }), index > 0 {
                Button(L10n.text("Close Left")) {
                    viewModel.closeDocumentsToLeft(of: document.id)
                }
            }
            if let index = viewModel.documents(in: viewModel.pane(for: document.id)).firstIndex(where: { $0.id == document.id }),
                index < viewModel.documents(in: viewModel.pane(for: document.id)).count - 1
            {
                Button(L10n.text("Close Right")) {
                    viewModel.closeDocumentsToRight(of: document.id)
                }
            }
            Divider()
            Button(L10n.text("Close Clean")) {
                viewModel.closeCleanDocuments()
            }
            Button(L10n.text("Close All")) {
                viewModel.closeAllDocuments()
            }
            if document.absolutePath != nil {
                Divider()
                Button(L10n.text("Copy Path")) {
                    onCopyDocumentPath?(document, false)
                }
                Button(L10n.text("Copy Relative Path")) {
                    onCopyDocumentPath?(document, true)
                }
                Divider()
                Button(L10n.text("Reveal in Finder")) {
                    onRevealDocument?(document)
                }
            }
        }
        .accessibilityIdentifier("AdaEditor.Tab.\(document.title)")
    }

    private func editorTabWidth(_ document: EditorWorkbenchDocument) -> Float {
        max(124, min(220, Float(tabTitle(for: document).count) * 7 + 64))
    }

    private func tabDropTarget(for documentID: String, translationX: Float) -> String? {
        let documents = viewModel.documents(in: viewModel.pane(for: documentID))
        guard let sourceIndex = documents.firstIndex(where: { $0.id == documentID }) else {
            return nil
        }

        var centers: [Float] = []
        var x: Float = 0
        for document in documents {
            let width = editorTabWidth(document)
            centers.append(x + width / 2)
            x += width + 4
        }

        let draggedCenter = centers[sourceIndex] + translationX
        let targetIndex = centers.indices.min { abs(centers[$0] - draggedCenter) < abs(centers[$1] - draggedCenter) } ?? sourceIndex
        return targetIndex == sourceIndex ? nil : documents[targetIndex].id
    }

    private func tabIcon(for document: EditorWorkbenchDocument) -> String {
        switch document {
        case .git:
            return "\u{E86F}"
        case .ui:
            return "\u{E871}"
        case .scene:
            return "\u{E8F1}"
        case .text(let document):
            return document.language == .swift ? "\u{E86F}" : "\u{E873}"
        case .asset(let document):
            switch document.kind {
            case .shaderGraph:
                return EditorProjectFileAppearance.shaderGraph.symbol
            case .particleEffect, .spriteAnimation, .atlas,
                .tileSource,
                .tileMap:
                return "\u{E8F1}"
            case .image:
                return "\u{E3F4}"
            case .model3D, .spine2D:
                return EditorProjectTreeIcon.mesh
            case .audio:
                return "\u{EB82}"
            case .generic:
                return "\u{E8F0}"
            }
        }
    }

    private func textLanguage(for document: EditorWorkbenchDocument) -> EditorSourceLanguage? {
        guard case .text(let document) = document else {
            return nil
        }
        return document.language
    }

    private func tabTitle(for document: EditorWorkbenchDocument) -> String {
        document.isDirty ? "\(document.title) *" : document.title
    }

    private func tabIconColor(for document: EditorWorkbenchDocument) -> Color {
        switch document {
        case .git:
            return theme.editorColors.blue
        case .ui:
            return theme.editorColors.blue
        case .scene:
            return theme.editorColors.purple
        case .text:
            return theme.editorColors.blue
        case .asset(let document):
            switch document.kind {
            case .shaderGraph:
                return EditorProjectFileAppearance.shaderGraph.color(in: theme.editorColors)
            case .particleEffect, .spriteAnimation, .atlas,
                .tileSource,
                .tileMap:
                return theme.editorColors.blue
            case .image:
                return theme.editorColors.blue
            case .model3D, .spine2D:
                return theme.editorColors.purple
            case .audio:
                return theme.editorColors.purple
            case .generic:
                return theme.editorColors.muted
            }
        }
    }

    @ViewBuilder
    private func activeDocumentView(in pane: EditorWorkbenchPane) -> some View {
        if filesBrowserPanes.contains(pane) {
            EditorFilesBrowserTab(items: projectItems) { item in
                filesBrowserPanes.remove(pane)
                onOpenProjectItem?(item)
            }
        } else {
            switch viewModel.selectedDocument(in: pane) {
            case .git(let document):
                EditorGitDiffView(document: document, workbench: viewModel)
            case .scene(let document):
                sceneDocumentEditor(document: document)
            case .ui(let document):
                EditorUISceneEditor(
                    model: viewModel.uiSceneModel(for: document, resourceRoot: sceneResourceRootURL, bindingCatalog: inspectorViewModel.scriptableObjectCatalog),
                    colorPalette: viewModel.codeColorPalette
                )
            case .text(let document):
                textDocumentEditor(document: document)
            case .asset(let document):
                assetPreview(document: document)
            case nil:
                emptyWorkbench
            }
        }
    }

    @ViewBuilder
    private func assetPreview(document: EditorAssetDocument) -> some View {
        switch document.kind {
        case .shaderGraph:
            EditorShaderGraphEditor(model: viewModel.shaderGraphModel(for: document), modelDocuments: viewModel.openDocuments.compactMap {
                if case .asset(let asset) = $0, asset.kind == .model3D { return asset }
                return nil
            }, workbench: viewModel).id(document.id)
        case .particleEffect:
            EditorParticleEffectAssetEditor(document: document, model: viewModel.particleEffectModel(for: document), workbench: viewModel)
                .id(document.id)
        case .spriteAnimation:
            EditorSpriteAnimationAssetEditor(document: document, model: viewModel.spriteAnimationModel(for: document), workbench: viewModel)
                .id(document.id)
        case .spine2D:
            EditorSpineAssetPreview(document: document, workbench: viewModel).id(document.id)
        case .model3D:
            EditorModelAssetPreview(document: document, workbench: viewModel, resourceRootURL: sceneResourceRootURL)
                .id(document.id)
        case .tileSource:
            EditorTileSourceAssetEditor(document: document, model: viewModel.tileSourceModel(for: document))
                .id(document.id)
        case .tileMap:
            EditorTileMapAssetEditor(document: document, model: viewModel.tileMapModel(for: document))
                .id(document.id)
        case .atlas:
            EditorTextureAtlasAssetEditor(document: document)
        case .image:
            EditorImageAssetPreview(document: document, model: viewModel.textureSettingsModel(for: document))
                .id(document.id)
        case .audio:
            EditorAudioAssetPreview(document: document)
                .id(document.id)
        case .generic:
            assetMetadataPreview(document: document)
        }
    }

    private func assetMetadataPreview(document: EditorAssetDocument) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            assetPreviewHeader(document: document)
            VStack(alignment: .leading, spacing: 10) {
                assetMetadataRow("Kind", document.kind == .audio ? "Audio" : "Asset")
                assetMetadataRow("Path", document.relativePath)
                if let assetReference = document.assetReference {
                    assetMetadataRow("Reference", assetReference)
                }
                assetMetadataRow("Extension", document.fileExtension.isEmpty ? "none" : document.fileExtension)
                if let byteCount = document.byteCount {
                    assetMetadataRow("Size", ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
                }
                if let modifiedAt = document.modifiedAt {
                    assetMetadataRow("Modified", modifiedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let errorMessage = document.errorMessage {
                    assetMetadataRow("Preview", errorMessage)
                }
            }
            .padding(14)
            .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.editorColors.background)
    }

    private func assetPreviewHeader(document: EditorAssetDocument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(document.title)
                .font(.system(size: 15))
                .foregroundColor(theme.editorColors.text)
            Text(document.assetReference ?? document.relativePath)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
        }
    }

    private func assetMetadataRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(L10n.tr(label))
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.text)
                .lineLimit(3)
            Spacer()
        }
    }

    private func assetPreviewError(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundColor(theme.editorColors.muted)
    }

    @ViewBuilder
    private func textDocumentEditor(document: EditorTextDocument) -> some View {
        switch document.id == viewModel.activeDocumentID ? viewModel.previewStatus : .hidden {
        case .hidden:
            codeFileView(document: document)
        default:
            GeometryReader { geometry in
                EditorPreviewPanelsLayout(state: previewResizeState) {
                    codeFileView(document: document)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    previewResizeHandle(availableWidth: geometry.size.width)

                    EditorPreviewPanel(
                        status: viewModel.previewStatus,
                        selectedPreviewID: viewModel.selectedPreviewID,
                        retainedPreviewView: viewModel.loadedPreview?.view,
                        onSelectPreview: { declaration in
                            onSelectPreview?(declaration)
                        },
                        onRebuild: {
                            onRebuildPreview?()
                        },
                        onHide: {
                            onHidePreview?()
                        },
                        onShowBuildOutput: {
                            onShowPreviewBuildOutput?()
                        }
                    )
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            }
        }
    }

    private func previewResizeHandle(availableWidth: Float) -> some View {
        ZStack {
            RectangleShape()
                .fill(theme.editorColors.border)
                .frame(width: 1)
            EditorResizeHandle(
                axis: .horizontal,
                onResize: { translation in
                    previewResizeState.resize(translation: translation.width, availableWidth: availableWidth)
                },
                onResizeEnded: {
                    previewResizeState.endDrag()
                }
            )
        }
        .frame(width: EditorPreviewSplitLayout.resizeHandleWidth)
        .frame(maxHeight: .infinity)
    }

    private func codeFileView(document: EditorTextDocument) -> some View {
        EditorCodeFileView(
            document: document,
            text: viewModel.textDocumentBinding(documentID: document.id),
            fontSize: viewModel.codeFontSize,
            fontFamily: viewModel.codeFontFamily,
            fontWeight: viewModel.codeFontWeight,
            keywordFontWeight: viewModel.keywordFontWeight,
            colorPalette: viewModel.codeColorPalette,
            onSourceHover: onSourceHover,
            onGoToDefinition: onGoToDefinition,
            onCompletionPosition: onCompletionPosition,
            onCompletionRequest: onCompletionRequest,
            onApplyCompletion: onApplyCompletion,
            onMoveCompletionSelection: onMoveCompletionSelection,
            onAcceptCompletion: onAcceptCompletion,
            onAcceptSnippetPlaceholder: onAcceptSnippetPlaceholder,
            onTextSelection: onTextSelection,
            onChatSelection: onChatSelection,
            sourceContextMenuItems: sourceContextMenuItems,
            onFileSearchQueryChange: { documentID, query in
                viewModel.updateFileSearchQuery(documentID: documentID, query: query)
            },
            onMoveFileSearchSelection: { documentID, delta in
                viewModel.moveFileSearchSelection(documentID: documentID, delta: delta)
            },
            onDismissFileSearch: { documentID in
                viewModel.dismissFileSearch(documentID: documentID)
            },
            debugger: debugger
        )
    }

    private var showsSceneControls: Bool {
        false
    }

    private var emptyWorkbench: some View {
        ZStack {
            // Match the surrounding project and inspector surfaces when no editor is open.
            theme.editorColors.surfaceElevated
            Text(L10n.text("No file selected"))
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sceneDocumentEditor(document: EditorSceneDocument) -> some View {
        EditorSceneDocumentEditor(
            document: document,
            workbench: viewModel,
            resourceRootURL: sceneResourceRootURL,
            uiCatalog: viewModel.uiCatalog,
            inspectorViewModel: inspectorViewModel,
            playModeState: playModeState,
            playRuntime: scenePlayRuntime,
            onEntitySelected: onSceneEntitySelected,
            onTerrainToolSelected: onTerrainToolSelected,
            onPlay: onPlayScene,
            onStop: onStopScene
        )
        .id("\(document.id).tilemap-\(viewModel.tileMapResourceRevision)")
        .accessibilityIdentifier("AdaEditor.SceneDocument.\(document.title)")
    }

    private func sceneDocumentHeader(document: EditorSceneDocument) -> some View {
        HStack(spacing: 8) {
            Text(document.title)
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.text)
            Text(document.relativePath)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
            Spacer()
            if let status = document.statusMessage {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundColor(document.isDirty ? theme.editorColors.purple : theme.editorColors.muted)
            }
            Button(action: { viewModel.appendSceneLine(documentID: document.id) }) {
                Text("\u{E145}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 14))
                    .foregroundColor(theme.editorColors.text)
                    .frame(width: 26, height: 22)
                    .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surfaceElevated))
            }
            .buttonStyle(DefaultButtonStyle())
            Button(action: { viewModel.saveSceneDocument(id: document.id) }) {
                Text(document.isDirty ? L10n.text("Save *") : L10n.text("Save"))
                    .font(.system(size: 10))
                    .foregroundColor(theme.editorColors.blue)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.blue.opacity(0.12)))
            }
            .buttonStyle(DefaultButtonStyle())
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(theme.editorColors.surface)
    }

    private func sceneDocumentTextEditor(document: EditorSceneDocument) -> some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.sceneLines(for: document).indices), id: \.self) { index in
                    sceneDocumentLine(document: document, lineIndex: index)
                }
            }
            .padding(.vertical, 10)
            .padding(.trailing, 28)
            .fixedSize(horizontal: true, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sceneDocumentLine(document: EditorSceneDocument, lineIndex: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(String(lineIndex + 1))
                .font(AdaEditorCodeFont.font(family: viewModel.codeFontFamily, weight: viewModel.codeFontWeight, size: viewModel.codeFontSize - 1))
                .foregroundColor(viewModel.codeColorPalette.lineNumber)
                .frame(width: 46, alignment: .trailing)
            TextField("", text: viewModel.sceneLineBinding(documentID: document.id, lineIndex: lineIndex))
                .font(AdaEditorCodeFont.font(family: viewModel.codeFontFamily, weight: viewModel.codeFontWeight, size: viewModel.codeFontSize))
                .foregroundColor(viewModel.codeColorPalette.plainText)
                .textFieldStyle(PlainTextFieldStyle())
                .frame(width: 820, height: max(22, Float(viewModel.codeFontSize * 1.8)), alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: max(24, Float(viewModel.codeFontSize * 2)))
        .background(lineIndex == 0 ? viewModel.codeColorPalette.currentLineBackground.opacity(0.55) : Color.clear)
    }

    private func sceneDocumentError(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Unable to open scene"))
                .font(.system(size: 13))
                .foregroundColor(theme.editorColors.text)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func viewportGrid(size: Size, metrics: AdaEngineStyleLayoutMetrics) -> some View {
        ZStack {
            VStack(spacing: metrics.gridRowSpacing(for: size)) {
                ForEach(0..<14) { index in
                    RectangleShape()
                        .fill(index == 7 ? theme.editorColors.blue.opacity(0.20) : theme.editorColors.border.opacity(0.32))
                        .frame(height: index == 7 ? 2 : 1)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, metrics.gridHorizontalPadding(for: size))
            .padding(.vertical, metrics.gridBottomPadding(for: size))

            HStack(spacing: metrics.gridColumnSpacing(for: size)) {
                ForEach(0..<18) { index in
                    RectangleShape()
                        .fill(index == 9 ? theme.editorColors.purple.opacity(0.18) : theme.editorColors.border.opacity(0.28))
                        .frame(width: index == 9 ? 2 : 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .padding(.horizontal, metrics.gridHorizontalPadding(for: size))
            .padding(.vertical, metrics.gridBottomPadding(for: size))
        }
    }

    private func viewportGizmo(size: Size, metrics: AdaEngineStyleLayoutMetrics) -> some View {
        let scale = metrics.gizmoScale(for: size)

        return VStack {
            Spacer(minLength: metrics.gizmoTopPadding(for: size))
            HStack {
                Spacer()
                ZStack {
                    CircleShape()
                        .fill(theme.editorColors.blue.opacity(0.16))
                        .frame(width: 86 * scale, height: 86 * scale)
                    RectangleShape()
                        .fill(theme.editorColors.blue.opacity(0.72))
                        .frame(width: 72 * scale, height: 2)
                    RectangleShape()
                        .fill(theme.editorColors.purple.opacity(0.70))
                        .frame(width: 2, height: 72 * scale)
                    CircleShape()
                        .fill(theme.editorColors.text.opacity(0.82))
                        .frame(width: 8 * scale, height: 8 * scale)
                }
                Spacer()
            }
            Spacer()
        }
    }

    private func viewportStatus(document: EditorSceneDocument) -> some View {
        VStack {
            HStack {
                Text(L10n.text("Scene · \(document.relativePath)"))
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface.opacity(0.88)))
                Spacer()
            }
            Spacer()
        }
    }

    private func aiFlightBox(metrics: AdaEngineStyleLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if metrics.showsAIHeader {
                HStack {
                    Text("▲  \(AdaEngineStyleContent.aiTitle.uppercased())")
                        .font(.system(size: 12))
                        .foregroundColor(theme.editorColors.purple)
                    Spacer()
                    Text(AdaEngineStyleContent.aiHint)
                        .font(.system(size: 10))
                        .foregroundColor(theme.editorColors.muted)
                }
            }
            TextField(AdaEngineStyleContent.aiPlaceholder, text: viewModel.aiPromptBinding)
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.text)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.background))
                .textFieldStyle(PlainTextFieldStyle())
                .accessibilityIdentifier("AdaEditor.AIFlightBox.Input")

            if metrics.showsAIChips {
                HStack(spacing: 8) {
                    ForEach(metrics.visibleAIChips, id: \.self) { chip in
                        aiChip(chip)
                    }
                    Spacer()
                    Button(action: {}) {
                        Text("\u{E5CC}")
                    }
                    .font(AdaEditorMaterialSymbolFont.font(size: 18))
                    .foregroundColor(theme.editorColors.purple)
                    .frame(width: 30, height: 28)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangleShape(cornerRadius: 16).fill(theme.editorColors.surface.opacity(0.96)))
        .frame(maxWidth: 350)
        .accessibilityIdentifier("AdaEditor.AIFlightBox")
    }

    private func aiChip(_ title: String) -> some View {
        Text(L10n.tr(title))
            .font(.system(size: 10))
            .foregroundColor(viewModel.hoveredChip == title ? theme.editorColors.text : theme.editorColors.purple)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangleShape(cornerRadius: 13).fill(viewModel.hoveredChip == title ? theme.editorColors.purple.opacity(0.24) : theme.editorColors.purple.opacity(0.10)))
            .overlay { RoundedRectangleShape(cornerRadius: 13).stroke(theme.editorColors.purple.opacity(0.35), lineWidth: 1) }
            .onHover { viewModel.hoveredChip = $0 ? title : nil }
    }
}

private struct EditorPreviewPanel: View {
    @State private var previewControls = EditorPreviewControls()
    let status: EditorPreviewStatus
    let selectedPreviewID: String?
    let retainedPreviewView: UIView?
    let onSelectPreview: (EditorPreviewDeclaration) -> Void
    let onRebuild: () -> Void
    let onHide: () -> Void
    let onShowBuildOutput: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: 34)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.editorColors.background)
        .accessibilityIdentifier("AdaEditor.PreviewPanel")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L10n.text("Preview"))
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.text)
            previewSelector
            Spacer()
            Button(action: onRebuild) {
                Text(L10n.text("Refresh"))
                    .font(.system(size: 10))
                    .foregroundColor(theme.editorColors.text)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surfaceElevated))
            }
            .buttonStyle(DefaultButtonStyle())
            Button(action: onHide) {
                Text("\u{E5CD}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 14))
                    .foregroundColor(theme.editorColors.muted)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surfaceElevated))
            }
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.PreviewPanel.Close")
        }
        .padding(.horizontal, 12)
        .background(theme.editorColors.surface)
    }

    @ViewBuilder
    private var previewSelector: some View {
        let declarations = declarations
        if declarations.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(declarations, id: \.id) { declaration in
                        Button(action: { onSelectPreview(declaration) }) {
                            Text(L10n.tr(declaration.title))
                                .font(.system(size: 10))
                                .foregroundColor(declaration.id == selectedPreviewID ? theme.editorColors.text : theme.editorColors.muted)
                                .padding(.horizontal, 7)
                                .frame(height: 22)
                                .background(RoundedRectangleShape(cornerRadius: 5).fill(selectorBackground(for: declaration)))
                        }
                        .buttonStyle(DefaultButtonStyle())
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .hidden:
            EmptyView()
        case .unavailable(let message):
            messageView(title: "Preview unavailable", message: message)
        case .available(let declarations):
            let selected = declarations.first { $0.id == selectedPreviewID } ?? declarations.first
            messageView(title: selected?.title ?? "Preview", message: "Build the preview to render it.")
        case .building(let declaration, let message):
            if let retainedPreviewView {
                retainedPreviewContent(retainedPreviewView) {
                    statusBanner(title: declaration.title, message: message, showsBuildOutputButton: false, isBuilding: true)
                }
            } else {
                progressView(title: declaration.title, message: message)
            }
        case .loaded(_, let view):
            EditorPreviewViewport(previewView: view, settings: previewControls)
                .padding(12)
        case .failed(let declaration, let message, let hasBuildOutput):
            if let retainedPreviewView {
                retainedPreviewContent(retainedPreviewView) {
                    statusBanner(
                        title: declaration?.title ?? "Preview failed",
                        message: message,
                        showsBuildOutputButton: hasBuildOutput
                    )
                }
            } else {
                messageView(title: declaration?.title ?? "Preview failed", message: message, showsBuildOutputButton: hasBuildOutput)
            }
        }
    }

    private var declarations: [EditorPreviewDeclaration] {
        switch status {
        case .available(let declarations):
            return declarations
        case .building(let declaration, _),
            .loaded(let declaration, _):
            return [declaration]
        case .failed(let declaration, _, _):
            return declaration.map { [$0] } ?? []
        case .hidden,
            .unavailable:
            return []
        }
    }

    private func selectorBackground(for declaration: EditorPreviewDeclaration) -> Color {
        declaration.id == selectedPreviewID ? theme.editorColors.blue.opacity(0.22) : theme.editorColors.surfaceElevated
    }

    private func progressView(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                EditorFlipLoadingIndicator(color: theme.editorColors.blue)
                    .accessibilityIdentifier("AdaEditor.Preview.BuildFlip")
                Text(L10n.tr(title))
                    .font(.system(size: 13))
                    .foregroundColor(theme.editorColors.text)
            }
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
            RoundedRectangleShape(cornerRadius: 2)
                .fill(theme.editorColors.blue.opacity(0.32))
                .frame(width: 180, height: 4)
                .overlay(anchor: .leading) {
                    RoundedRectangleShape(cornerRadius: 2)
                        .fill(theme.editorColors.blue)
                        .frame(width: 72, height: 4)
                }
            showBuildOutputButton
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func retainedPreviewContent<Overlay: View>(
        _ view: UIView,
        @ViewBuilder overlay: @escaping () -> Overlay
    ) -> some View {
        ZStack(anchor: .topLeading) {
            EditorPreviewViewport(previewView: view, settings: previewControls)
                .padding(12)
            overlay()
                .padding(12)
        }
    }

    private func statusBanner(
        title: String,
        message: String,
        showsBuildOutputButton: Bool,
        isBuilding: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if isBuilding {
                    EditorFlipLoadingIndicator(size: 12, color: theme.editorColors.blue)
                        .accessibilityIdentifier("AdaEditor.Preview.BannerFlip")
                }
                Text(L10n.tr(title))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.editorColors.text)
            }
            Text(message)
                .font(.system(size: 10))
                .foregroundColor(theme.editorColors.muted)
            if showsBuildOutputButton {
                showBuildOutputButton
            }
        }
        .padding(10)
        .background(RoundedRectangleShape(cornerRadius: 7).fill(theme.editorColors.surfaceElevated.opacity(0.94)))
        .overlay {
            RoundedRectangleShape(cornerRadius: 7)
                .stroke(theme.editorColors.border, lineWidth: 1)
        }
    }

    private func messageView(title: String, message: String, showsBuildOutputButton: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr(title))
                .font(.system(size: 13))
                .foregroundColor(theme.editorColors.text)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
            if showsBuildOutputButton {
                showBuildOutputButton
                    .padding(.top, 2)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var showBuildOutputButton: some View {
        Button(action: onShowBuildOutput) {
            Text(L10n.text("Show Build Output"))
                .font(.system(size: 10))
                .foregroundColor(theme.editorColors.blue)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.blue.opacity(0.12)))
        }
        .buttonStyle(DefaultButtonStyle())
    }
}

struct EditorPreviewSplitLayout {
    static let defaultPreviewWidth: Float = 360
    static let minimumPreviewWidth: Float = 260
    static let minimumEditorWidth: Float = 320
    static let resizeHandleWidth: Float = 8

    static func previewWidth(requestedWidth: Float, availableWidth: Float) -> Float {
        let maximumWidth = max(0, availableWidth - resizeHandleWidth - minimumEditorWidth)
        guard maximumWidth >= minimumPreviewWidth else {
            return maximumWidth
        }
        return min(max(requestedWidth, minimumPreviewWidth), maximumWidth)
    }
}
