//
//  EditorWindow.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/31/22.
//

@_spi(AdaEngine) import AdaEngine

enum AdaEngineStyleContent {
    static let topToolbarLabels = ["Search Everywhere", "main_scene", "Run"]
    static let leftTopSidebarTools = [
        EditorToolStripItem(identifier: "fileTree", title: "File Tree", icon: "\u{E2C7}"),
        EditorToolStripItem(identifier: "sourceControl", title: "Source Control", icon: "\u{F1C4}"),
    ]
    static let leftBottomSidebarTools = [
        EditorToolStripItem(identifier: "logs", title: "Logs", icon: "\u{EB8E}"),
        EditorToolStripItem(identifier: "build", title: "Build", icon: "\u{E869}"),
        EditorToolStripItem(identifier: "debug", title: "Debug", icon: "\u{E868}"),
        EditorToolStripItem(identifier: "animator", title: "Animator", icon: "\u{E71C}"),
    ]
    static let rightSidebarTools = [
        EditorToolStripItem(identifier: "agentChat", title: "Agent Chat", icon: "\u{E65F}"),
        EditorToolStripItem(identifier: "inspector", title: "Inspector", icon: "\u{E88E}"),
        EditorToolStripItem(
            identifier: "projectDependencies",
            title: "Project Dependencies",
            icon: "\u{E48F}"
        ),
        EditorToolStripItem(
            identifier: "swiftPackageTasks",
            title: "Swift Package Tasks",
            icon: "\u{F720}"
        ),
        EditorToolStripItem(identifier: "plugins", title: "Plugins", icon: "\u{E87B}"),
        EditorToolStripItem(
            identifier: "projectSettings",
            title: "Project Settings",
            icon: "\u{E8B8}"
        ),
    ]
    static let projectTreeItems = ["src", "EngineLoop.ada", "Renderer.ada", "Main.ascn"]
    static let editorTabs = ["EngineLoop.ada", "Main.ascn"]
    static let sampleTextDocuments = [
        "src/EngineLoop.ada": """
        import AdaEngine

        @system
        struct EngineLoop {
            let fixedDelta = 1.0 / 60.0

            func update(scene: Scene, deltaTime: Float) {
                // Game simulation entry point.
                scene.physics.step(deltaTime)
            }
        }
        """,
        "src/Renderer.ada": """
        render_pipeline MainRenderer {
            colorAttachment = .hdr
            depthTest = true

            pass geometry {
                shader = "Shaders/MainSurface.glsl"
            }
        }
        """,
    ]
    static let defaultSceneModel = EditorSceneModel.default(projectName: "Main")
    static let defaultSceneContent =
        (try? defaultSceneModel.encodedYAML())
        ?? SceneDocumentFormat.defaultSceneYAML(projectName: "Main")
    static let defaultEditorDocuments: [EditorWorkbenchDocument] = [
        .text(
            EditorTextDocument(
                id: "text:src/EngineLoop.ada",
                title: "EngineLoop.ada",
                relativePath: "src/EngineLoop.ada",
                language: .ada,
                content: sampleTextDocuments["src/EngineLoop.ada"] ?? "",
                errorMessage: nil
            )
        ),
        .scene(
            EditorSceneDocument(
                id: "scene:Assets/Scenes/Main.ascn",
                title: "Main.ascn",
                relativePath: "Assets/Scenes/Main.ascn",
                absolutePath: nil,
                content: defaultSceneContent,
                sceneModel: defaultSceneModel,
                errorMessage: nil,
                isDirty: false,
                statusMessage: "Sample scene",
                loadSummary: EditorSceneFileLoader.summary(from: defaultSceneContent)
            )
        ),
    ]
    static let aiTitle = "Ada Intelligence"
    static let aiHint = "⌘L to Focus"
    static let aiPlaceholder = "Ask to generate logic, optimize shaders, or place objects..."
    static let aiChips = ["Refactor current scene", "Optimize render batches", "Auto-light"]
    static let inspectorScript = "DynamicBouncer.ada"
    static let inspectorScriptDescription = "Object bounces on contact"
    static let outputTabs = ["Problems", "Build", "Tests", "References", "Output", "Performance"]
    static let logLines = [
        "[12:04:11] Ada initialized — render backend ready.",
        "[12:04:12] Loaded Main.ascn with 1 entity.",
        "[12:04:14] AI optimization note: draw calls can be batched by material.",
        "[12:04:16] Build completed with 0 problems.",
    ]
}

struct EditorView: View {
    let project: EditorProjectReference?
    @State private var viewModel: EditorViewModel
    @State private var projectSwitcher: EditorProjectSwitcherViewModel
    @State private var isRunDestinationMenuPresented = false
    @Environment(\.theme) private var theme

    init(project: EditorProjectReference?, viewModel: EditorViewModel? = nil) {
        self.project = project
        self._viewModel = State(initialValue: viewModel ?? EditorViewModel(project: project))
        self._projectSwitcher = State(initialValue: EditorProjectSwitcherViewModel(currentProject: project))
    }

    private var editorContent: some View {
        GeometryReader { geometry in
            let metrics = AdaEngineStyleLayoutMetrics(size: geometry.size)
            VStack(spacing: metrics.workspaceSpacer) {
                EditorTopToolbarRegion(
                    viewModel: viewModel,
                    projectSwitcher: projectSwitcher,
                    isRunDestinationMenuPresented: isRunDestinationMenuPresented,
                    onToggleRunDestinationMenu: {
                        projectSwitcher.dismiss()
                        isRunDestinationMenuPresented.toggle()
                    },
                    onToggleProjectSwitcher: {
                        isRunDestinationMenuPresented = false
                        projectSwitcher.toggle()
                    }
                )
                .onAppear {
                    viewModel.startEditorSessionIfNeeded()
                }
                .frame(height: metrics.topToolbarHeight)
                .zIndex(10)

                EditorWorkspaceRegion(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                EditorFooterRegion(viewModel: viewModel)
                    .frame(height: metrics.footerHeight)
            }
            .frame(
                minWidth: 0,
                maxWidth: .infinity,
                minHeight: 0,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .foregroundColor(theme.editorColors.text)
            .environment(\.metrics, metrics)
            .overlay(anchor: .bottomTrailing) {
                EditorNotificationOverlay(model: viewModel, size: geometry.size)
            }
            .overlay(anchor: .top) {
                if !viewModel.toolbar.searchResults.isEmpty {
                    EditorProjectSearchResults(
                        items: viewModel.toolbar.searchResults,
                        width: metrics.toolbarSearchWidth,
                        onOpenSearchResult: { item in
                            viewModel.openSearchResult(item)
                        }
                    )
                    .frame(height: EditorProjectSearchResultsLayout.height(itemCount: viewModel.toolbar.searchResults.count))
                    .offset(y: EditorProjectSearchResultsLayout.topOffset(toolbarHeight: metrics.topToolbarHeight))
                }
            }
            .overlay(anchor: .topLeading) {
                if projectSwitcher.isPresented {
                    ZStack(anchor: .topLeading) {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .onTapGesture {
                                projectSwitcher.dismiss()
                            }

                        EditorProjectSwitcherPanel(
                            viewModel: projectSwitcher,
                            onOpenProject: { project in
                                ProjectEditorLauncher.openEditor(for: project)
                            }
                        )
                        .frame(width: EditorProjectSwitcherLayout.width, height: EditorProjectSwitcherLayout.height)
                        .offset(
                            x: EditorProjectSwitcherLayout.leadingOffset,
                            y: EditorProjectSwitcherLayout.topOffset(toolbarHeight: metrics.topToolbarHeight)
                        )
                    }
                    .zIndex(20)
                }
            }
            .overlay(anchor: .topTrailing) {
                EditorRunDestinationOverlay(
                    isPresented: isRunDestinationMenuPresented,
                    selectedDestination: viewModel.selectedRunDestination,
                    toolbarHeight: metrics.topToolbarHeight,
                    onDismiss: { isRunDestinationMenuPresented = false },
                    onSelect: viewModel.selectRunDestination
                )
            }
        }
        .padding(.all, 4)
        .background {
            EditorSafeAreaBackground()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            EditorAgentActivityOverlay(state: viewModel.agent.activityState, activityID: viewModel.agent.lastActivityID)
        }
    }

    var body: some View {
        // Keep the window presentation value small as editor overlays grow.
        AnyView(editorContent)
            .modifier(EditorTextSearchPresentation(viewModel: viewModel))
            .fullScreenCover(isPresented: viewModel.isNewFileDialogPresentedBinding) {
                EditorNewFileDialog(viewModel: viewModel)
            }
            .fullScreenCover(
                item: Binding(
                    get: { viewModel.workbench.entityPickerRequest },
                    set: { viewModel.workbench.entityPickerRequest = $0 }
                )
            ) { request in
                EditorEntityPickerDialog(workbench: viewModel.workbench, request: request)
            }
            .fullScreenCover(
                item: Binding(
                    get: { viewModel.workbench.modifierPickerRequest },
                    set: { viewModel.workbench.modifierPickerRequest = $0 }
                )
            ) { request in
                EditorAddModifierDialog(model: request.model, nodeID: request.nodeID)
            }
            .fullScreenCover(isPresented: viewModel.inspectorSidebar.componentPickerPresentationBinding) {
                EditorAddComponentDialog(viewModel: viewModel.inspectorSidebar)
            }
            #if os(iOS)
                .fullScreenCover(item: viewModel.settingsPresentationBinding) { section in
                    EditorSettingsWindowView(
                        viewModel: EditorSettingsWindowViewModel(editorViewModel: viewModel, selectedSection: section),
                        showsCloseButton: true
                    )
                    .theme(.adaEditor)
                }
            #endif
            .alert(
                "Delete item?",
                isPresented: viewModel.isDeleteProjectItemAlertPresentedBinding,
                presenting: viewModel.pendingDeleteProjectItem,
                actions: { item in
                    Button("Cancel", role: .cancel) {}
                    Button("Delete", role: .destructive) {
                        viewModel.deleteProjectItem(item)
                    }
                },
                message: { item in
                    Text("\(item.title) will be permanently deleted from the project.")
                }
            )
            .menuBar(EditorMenuBar.makeMenus())
            .keyboardShortcuts(editorKeyboardShortcuts)
            #if os(macOS)
                .onChange(of: viewModel.settingsPresentationToken) { _, _ in
                    guard let section = viewModel.requestedSettingsSection else {
                        return
                    }
                    EditorSettingsWindowController.open(editorViewModel: viewModel, selectedSection: section)
                }
            #endif
            .task {
                RuntimeLogStore.shared.setEnabled(true)
                while !Task.isCancelled {
                    await viewModel.collectRuntimeLogs()
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                }
            }
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    // The branch can also change in a terminal while the editor stays open.
                    await viewModel.refreshSourceControlFooter()
                }
            }
            .onAppear {
                viewModel.startProjectFileWatching()
                EditorNotificationRouter.shared.attach(viewModel)
                EditorMenuCommandRouter.shared.install(owner: viewModel) { [weak viewModel] command in
                    viewModel?.handleMenuCommand(command) ?? false
                }
                EditorSearchShortcutMonitor.shared.start()
                EditorNavigationMouseShortcutMonitor.shared.start(
                    back: { [weak viewModel] in viewModel?.navigateBack() },
                    forward: { [weak viewModel] in viewModel?.navigateForward() }
                )
            }
            .onDisappear {
                viewModel.playerSession.disconnect()
                viewModel.playerPairingWindow?.close()
                viewModel.playerPairingWindow = nil
                viewModel.stopProjectFileWatching()
                EditorNotificationRouter.shared.detach(viewModel)
                viewModel.debugger.stop()
                EditorMenuCommandRouter.shared.uninstall(owner: viewModel)
                EditorSearchShortcutMonitor.shared.stop()
                EditorNavigationMouseShortcutMonitor.shared.stop()
            }
            .debugOverlay(viewModel.showsDebugOverlay ?? .off)
    }

    private var editorKeyboardShortcuts: [KeyboardShortcutAction] {
        EditorHistoryShortcuts.actions { EditorMenuCommandRouter.shared.perform($0) } + [
            KeyboardShortcutAction(.r, modifiers: .command) {
                viewModel.toggleDebugOverlay(.redraw)
            },
            KeyboardShortcutAction(.d, modifiers: .command) {
                viewModel.toggleDebugOverlay(.layoutBounds)
            },
            KeyboardShortcutAction(.h, modifiers: .command) {
                viewModel.toggleDebugOverlay(.hitTestTarget)
            },
            KeyboardShortcutAction(.f, modifiers: .command) {
                viewModel.toggleDebugOverlay(.focusedNode)
            },
            KeyboardShortcutAction(.s, modifiers: .command) {
                viewModel.saveActiveDocument()
            },
            KeyboardShortcutAction(.leftBracket, modifiers: .command) {
                viewModel.navigateBack()
            },
            KeyboardShortcutAction(.rightBracket, modifiers: .command) {
                viewModel.navigateForward()
            },
            KeyboardShortcutAction(.plus, modifiers: .command) {
                viewModel.workbench.increaseCodeFontSize()
            },
            KeyboardShortcutAction(.equals, modifiers: .command) {
                viewModel.workbench.increaseCodeFontSize()
            },
            KeyboardShortcutAction(.minus, modifiers: .command) {
                viewModel.workbench.decreaseCodeFontSize()
            },
            KeyboardShortcutAction(.num0, modifiers: .command) {
                viewModel.workbench.resetCodeFontSize()
            },
            KeyboardShortcutAction(.plus, modifiers: .control) {
                viewModel.workbench.increaseCodeFontSize()
            },
            KeyboardShortcutAction(.equals, modifiers: .control) {
                viewModel.workbench.increaseCodeFontSize()
            },
            KeyboardShortcutAction(.minus, modifiers: .control) {
                viewModel.workbench.decreaseCodeFontSize()
            },
            KeyboardShortcutAction(.num0, modifiers: .control) {
                viewModel.workbench.resetCodeFontSize()
            },
        ]
    }
}

private struct EditorWorkspaceRegion: View {
    let viewModel: EditorViewModel
    @Environment(\.metrics) private var metrics

    var body: some View {
        GeometryReader { geometry in
            let stripWidth = metrics.toolStripWidth
            let workspaceWidth = max(0, geometry.size.width - stripWidth * 2)

            ZStack(anchor: .topLeading) {
                EditorLeftToolStrip(
                    viewModel: viewModel,
                    onSelectTopTool: { item in
                        viewModel.activateLeftTopTool(item)
                    },
                    onSelectBottomTool: { item in
                        viewModel.activateLeftBottomTool(item)
                    }
                )
                .frame(width: stripWidth, height: geometry.size.height)

                EditorWorkspaceView(
                    viewModel: viewModel,
                    leftPanel: {
                        EditorLeftSidebarContent(viewModel: viewModel)
                    },
                    mainPanel: {
                        EditorCenterWorkbench(
                            viewModel: viewModel.workbench,
                            inspectorViewModel: viewModel.inspectorSidebar,
                            playModeState: viewModel.playModeState,
                            scenePlayRuntime: viewModel.scenePlayRuntime,
                            sceneResourceRootURL: viewModel.projectAssetsURL,
                            onPlayScene: viewModel.runActiveSceneInEditor,
                            onStopScene: viewModel.stopPlayMode,
                            onSceneEntitySelected: viewModel.presentSceneInspector,
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
                            debugger: viewModel.debugger
                        )
                        .frame(maxHeight: .infinity)
                    },
                    rightPanel: {
                        EditorRightSidebarContent(viewModel: viewModel)
                    },
                    bottomPanel: {
                        if viewModel.toolStrip.activeLeftBottomTool == "animator" {
                            EditorAnimationPanel(viewModel: viewModel)
                        } else if viewModel.toolStrip.activeLeftBottomTool == "debug" {
                            EditorDebugPanel(debugger: viewModel.debugger)
                        } else {
                            EditorBottomPanel(viewModel: viewModel)
                        }
                    }
                )
                .frame(width: workspaceWidth, height: geometry.size.height)
                .offset(x: stripWidth)

                EditorRightToolStrip(
                    viewModel: viewModel,
                    onSelectTool: { item in
                        viewModel.activateRightTool(item)
                    }
                )
                .frame(width: stripWidth, height: geometry.size.height)
                .offset(x: stripWidth + workspaceWidth)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .frame(
            minWidth: 0,
            maxWidth: .infinity,
            minHeight: 0,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}

private struct EditorLeftSidebarContent: View {
    let viewModel: EditorViewModel

    var body: some View {
        if viewModel.toolStrip.activeLeftTopTool == "sourceControl" {
            EditorSourceControlSidebar(viewModel: viewModel)
        } else {
            EditorProjectSidebar(
                viewModel: viewModel.projectSidebar,
                projectRootItem: viewModel.projectRootSidebarItem,
                onOpenItem: { item in
                    viewModel.openProjectItem(item)
                },
                onOpenRawItem: { item in
                    viewModel.openProjectItemAsRaw(item)
                },
                onNewFile: { kind in
                    viewModel.presentNewFileDialog(kind: kind)
                },
                onImportAssets: {
                    viewModel.importAssets()
                },
                onDropFiles: { urls in
                    viewModel.importDroppedFiles(from: urls)
                },
                onRevealItem: { item in
                    viewModel.revealProjectItem(item)
                },
                onOpenInDefaultApplication: { item in
                    viewModel.openProjectItemInDefaultApplication(item)
                },
                onOpenInTerminal: { item in
                    viewModel.openProjectItemInTerminal(item)
                },
                onFindInFolder: { item in
                    viewModel.findInProjectFolder(item)
                },
                onFindInProjectRoot: {
                    viewModel.findInProjectRoot()
                },
                onCopyPath: { item, relative in
                    viewModel.copyProjectItemPath(item, relative: relative)
                },
                onDeleteItem: { item in
                    viewModel.presentDeleteProjectItemAlert(item)
                }
            )
        }
    }
}

private struct EditorRightSidebarContent: View {
    let viewModel: EditorViewModel

    var body: some View {
        if viewModel.toolStrip.activeRightTool == "agentChat" {
            EditorAgentSidebar(viewModel: viewModel.agent, onOpenCatalog: { viewModel.presentSettings(.agent) })
        } else if viewModel.toolStrip.activeRightTool == "inspector" {
            EditorContextualInspector(
                document: viewModel.workbench.activeDocument,
                workbench: viewModel.workbench,
                sceneInspectorViewModel: viewModel.inspectorSidebar,
                resourceRootURL: viewModel.projectAssetsURL
            )
        } else {
            EditorProjectToolSidebar(viewModel: viewModel)
        }
    }
}

private struct EditorFooterRegion: View {
    let viewModel: EditorViewModel

    var body: some View {
        HStack(spacing: 4) {
            EditorFooter(
                viewModel: viewModel.footer,
                activities: viewModel.activeActivities,
                onOpenActivity: {
                    viewModel.notificationTab = .activity
                    viewModel.showsNotifications = true
                }
            )
            .frame(maxWidth: .infinity)
            EditorNotificationBell(model: viewModel)
        }
    }
}

struct EditorResizeHandle: View {
    enum Axis {
        case horizontal
        case vertical
    }

    let axis: Axis
    let onResize: (Size) -> Void
    let onResizeEnded: () -> Void

    init(
        axis: Axis,
        onResize: @escaping (Size) -> Void = { _ in },
        onResizeEnded: @escaping () -> Void = {}
    ) {
        self.axis = axis
        self.onResize = onResize
        self.onResizeEnded = onResizeEnded
    }

    @ViewBuilder
    var body: some View {
        switch axis {
        case .horizontal:
            hitArea
                .frame(width: 8)
                .frame(maxHeight: .infinity)
        case .vertical:
            hitArea
                .frame(height: 8)
                .frame(maxWidth: .infinity)
        }
    }

    private var hitArea: some View {
        RectangleShape()
            .fill(Color.clear)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        onResize(value.translation)
                    }
                    .onEnded { _ in
                        onResizeEnded()
                    }
            )
            .cursorShape(cursorShape)
    }

    private var cursorShape: Input.CursorShape {
        switch axis {
        case .horizontal:
            return .resizeLeftRight
        case .vertical:
            return .resizeUpDown
        }
    }
}

extension Glass {
    private static func editorWindowBackground(theme: Theme) -> Glass {
        var glass = Self.regular
        glass.blurRadius = 24
        glass.glassTintStrength = 0.72
        glass.edgeShadowStrength = 0
        glass.tintColor = theme.editorColors.background.opacity(0.18)
        return glass
    }
}
