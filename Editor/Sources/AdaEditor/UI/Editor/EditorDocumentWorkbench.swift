@_spi(AdaEngine) import AdaEngine

/// Both interfaces use the same document model, renderer, and editing callbacks.
struct EditorDocumentWorkbench: View {
    let viewModel: EditorViewModel

    var body: some View {
        ZStack {
            EditorCenterWorkbench(
                viewModel: viewModel.workbench,
                inspectorViewModel: viewModel.inspectorSidebar,
                playModeState: viewModel.playModeState,
                scenePlayRuntime: viewModel.scenePlayRuntime,
                sceneResourceRootURL: viewModel.projectAssetsURL,
                onPlayScene: viewModel.runActiveSceneInEditor,
                onStopScene: viewModel.stopPlayMode,
                onSceneEntitySelected: viewModel.presentSceneInspectorForSelection,
                onSourceHover: { document, position in
                    viewModel.handleSourceHover(document: document, position: position)
                },
                onGoToDefinition: { document, position in
                    viewModel.goToDefinition(document: document, position: position)
                },
                onCompletionPosition: { document, position, text in
                    viewModel.handleCompletionPosition(document: document, position: position, text: text)
                },
                onCompletionRequest: { document, position, text in
                    viewModel.handleCompletionRequest(document: document, position: position, text: text)
                },
                onApplyCompletion: { item, document in
                    viewModel.applyCompletion(item, to: document)
                },
                onMoveCompletionSelection: { document, delta in
                    viewModel.moveCompletionSelection(in: document, by: delta)
                },
                onAcceptCompletion: { document in
                    viewModel.applySelectedCompletion(in: document)
                },
                onAcceptSnippetPlaceholder: { document, selection in
                    viewModel.acceptSnippetPlaceholder(in: document, selection: selection)
                },
                onTextSelection: { document, range, text in
                    viewModel.handleTextSelection(document: document, range: range, text: text)
                },
                onChatSelection: { document, range, text in
                    viewModel.chatAboutTextSelection(document: document, range: range, text: text)
                },
                sourceContextMenuItems: { document, position in
                    viewModel.sourceContextMenuItems(document: document, position: position)
                },
                onSelectDocument: { documentID in
                    viewModel.selectWorkbenchDocument(id: documentID)
                },
                onRevealDocument: { document in
                    viewModel.revealDocument(document)
                },
                onCopyDocumentPath: { document, relative in
                    viewModel.copyDocumentPath(document, relative: relative)
                },
                onSelectPreview: { declaration in
                    viewModel.selectPreview(declaration)
                },
                onRebuildPreview: {
                    viewModel.rebuildSelectedPreview()
                },
                onHidePreview: {
                    viewModel.hidePreview()
                },
                onShowPreviewBuildOutput: {
                    viewModel.showBuildOutput()
                },
                debugger: viewModel.debugger,
                projectItems: viewModel.projectSidebar.items,
                onOpenProjectItem: { item in
                    viewModel.openProjectItem(item)
                }
            )
            .frame(maxHeight: .infinity)
            .allowsHitTesting(!viewModel.performance.isExpanded)
            if viewModel.performance.isExpanded {
                EditorPerformancePanel(model: viewModel.performance, isWorkspace: true)
            }
        }
    }
}
