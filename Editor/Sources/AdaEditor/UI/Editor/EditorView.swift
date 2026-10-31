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
        EditorToolStripItem(identifier: "logs", title: EditorDistribution.current == .standalone ? "Terminal" : "Logs", icon: "\u{EB8E}"),
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
        """
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
    static let logLines: [String] = []
}

struct EditorView: View {
    let project: EditorProjectReference?
    let usesNativeOrnaments: Bool
    @State private var viewModel: EditorViewModel
    @State private var projectSwitcher: EditorProjectSwitcherViewModel
    @State private var isRunDestinationMenuPresented = false
    @Environment(\.theme) private var theme

    init(project: EditorProjectReference?, viewModel: EditorViewModel? = nil, usesNativeOrnaments: Bool = false) {
        self.project = project
        self.usesNativeOrnaments = usesNativeOrnaments
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
                        viewModel.buildTargets.isMenuPresented = false
                        isRunDestinationMenuPresented.toggle()
                    },
                    onToggleProjectSwitcher: {
                        isRunDestinationMenuPresented = false
                        viewModel.buildTargets.isMenuPresented = false
                        projectSwitcher.toggle()
                    }
                )
                .onAppear {
                    viewModel.startEditorSessionIfNeeded()
                }
                .frame(height: metrics.topToolbarHeight)
                .zIndex(10)

                #if os(macOS) || os(Windows) || os(Linux) || os(visionOS)
                if viewModel.interface.mode == .agent {
                    EditorAgentWorkspace(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EditorWorkspaceRegion(viewModel: viewModel, usesNativeOrnaments: usesNativeOrnaments)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                #else
                EditorWorkspaceRegion(viewModel: viewModel, usesNativeOrnaments: usesNativeOrnaments)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif

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
                    onSelect: viewModel.selectRunDestination,
                    androidTargets: viewModel.androidTargets,
                    selectedAndroidTargetID: viewModel.selectedAndroidTargetID,
                    androidStatus: viewModel.androidStatus,
                    onSelectAndroid: viewModel.selectAndroidTarget,
                    onRefreshAndroid: viewModel.refreshAndroidTargets,
                    onAndroidSettings: { viewModel.presentSettings(.buildExport, page: "ANDROID") }
                )
            }
            .overlay(anchor: .topTrailing) {
                if viewModel.buildTargets.isMenuPresented {
                    ZStack(anchor: .topTrailing) {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .onTapGesture { viewModel.buildTargets.isMenuPresented = false }
                        EditorBuildTargetMenu(viewModel: viewModel)
                            .offset(x: -(metrics.toolbarRunControlsWidth + metrics.toolbarRunDestinationWidth + 40),
                                    y: metrics.topToolbarHeight - 2)
                    }.zIndex(31)
                }
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
            .fullScreenCover(isPresented: Binding(
                get: { viewModel.buildTargets.isPresented }, set: { viewModel.buildTargets.isPresented = $0 }
            )) {
                EditorBuildTargetsDialog(viewModel: viewModel)
            }
            .fullScreenCover(isPresented: viewModel.movieMakerPresentation) {
                EditorMovieMakerDialog(
                    model: viewModel.movieMaker,
                    canStart: viewModel.canStartMovie,
                    onStart: viewModel.startMovieRecording,
                    onBrowse: viewModel.browseMovieFolder,
                    onClose: { viewModel.movieMaker.saveSettings(); viewModel.movieMaker.isPresented = false },
                    onReveal: {
                        if let url = viewModel.movieMaker.outputURL { _ = viewModel.externalURLOpener(url.deletingLastPathComponent()) }
                    }
                )
            }
            .modifier(EditorStudioToolPermissionPresentation(host: viewModel.studioTools, presentation: .workspace))
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
                    viewModel: EditorSettingsWindowViewModel(
                        editorViewModel: viewModel,
                        selectedSection: section,
                        selectedPage: viewModel.requestedSettingsPage
                    ),
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
                    Button(L10n.text("Cancel"), role: .cancel) {}
                    Button(L10n.text("Delete"), role: .destructive) {
                        viewModel.deleteProjectItem(item)
                    }
                },
                message: { item in
                    Text(L10n.text("\(item.title) will be permanently deleted from the project."))
                }
            )
            .menuBar(EditorMenuBar.makeMenus(), foregroundColor: theme.editorColors.text, backgroundColor: theme.editorColors.surface)
            .keyboardShortcuts(editorKeyboardShortcuts)
        #if os(macOS) || os(Windows) || os(Linux)
            .onChange(of: viewModel.settingsPresentationToken) { _, _ in
                guard let section = viewModel.requestedSettingsSection else {
                    return
                }
                EditorSettingsWindowController.open(
                    editorViewModel: viewModel,
                    selectedSection: section,
                    selectedPage: viewModel.requestedSettingsPage
                )
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
                EditorAgentMCPTools.shared.activate(viewModel)
                viewModel.startStudioTools()
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
                viewModel.terminals.stop()
                viewModel.tests.stopDiscovery()
                EditorAgentMCPTools.shared.deactivate(viewModel)
                viewModel.disconnectAdaPlayer()
                viewModel.playerPairingWindow?.close()
                viewModel.playerPairingWindow = nil
                viewModel.stopProjectFileWatching()
                viewModel.studioTools.close()
                viewModel.movieMaker.cancel()
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
            KeyboardShortcutAction(.f, modifiers: .command) {
                _ = viewModel.handleMenuCommand(.findInFile)
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
    let usesNativeOrnaments: Bool
    @Environment(\.metrics) private var metrics

    var body: some View {
        GeometryReader { geometry in
            let stripWidth: Float = usesNativeOrnaments ? 0 : metrics.toolStripWidth
            let workspaceWidth = max(0, geometry.size.width - stripWidth * 2)

            ZStack(anchor: .topLeading) {
                EditorWorkspaceView(
                    viewModel: viewModel,
                    leftPanel: {
                        EditorLeftSidebarContent(viewModel: viewModel)
                    },
                    mainPanel: {
                        EditorDocumentWorkbench(viewModel: viewModel, showsDocumentTabs: !usesNativeOrnaments)
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

                if !usesNativeOrnaments {
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

                    EditorRightToolStrip(
                        viewModel: viewModel,
                        onSelectTool: { item in
                            viewModel.activateRightTool(item)
                        }
                    )
                    .frame(width: stripWidth, height: geometry.size.height)
                    .offset(x: stripWidth + workspaceWidth)
                }
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

struct EditorLeftSidebarContent: View {
    let viewModel: EditorViewModel
    var tool: String? = nil

    var body: some View {
        if (tool ?? viewModel.toolStrip.activeLeftTopTool) == "sourceControl" {
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
                },
                onRevealActiveFile: { viewModel.revealActiveDocumentInProjectTree() },
                isRevealActiveFileEnabled: viewModel.canRevealActiveDocumentInProjectTree
            )
        }
    }
}

private struct EditorRightSidebarContent: View {
    let viewModel: EditorViewModel

    var body: some View {
        if viewModel.toolStrip.activeRightTool == "agentChat" {
            EditorAgentSidebar(viewModel: viewModel.agent, onOpenCatalog: { viewModel.presentSettings(.agent) })
        } else if viewModel.toolStrip.activeRightTool == "studioTools" {
            EditorStudioToolsSidebar(host: viewModel.studioTools, onOpenSettings: {
                viewModel.presentSettings(.project, page: EditorSettingsPage.studioTools)
            })
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
    var showsGrip = false

    @State private var isHovered = false
    @State private var isDragging = false
    @Environment(\.theme) private var theme

    init(
        axis: Axis,
        onResize: @escaping (Size) -> Void = { _ in },
        onResizeEnded: @escaping () -> Void = {},
        showsGrip: Bool = false
    ) {
        self.axis = axis
        self.onResize = onResize
        self.onResizeEnded = onResizeEnded
        self.showsGrip = showsGrip
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
            .overlay {
                if showsGrip {
                    RoundedRectangleShape(cornerRadius: 1.5)
                        .fill(isHovered || isDragging ? theme.editorColors.blue : theme.editorColors.muted.opacity(0.6))
                        .frame(width: axis == .horizontal ? 3 : 28, height: axis == .vertical ? 3 : 28)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("AdaEditor.ResizeHandle.Grip")
                }
            }
            .overlay {
                if isHovered || isDragging {
                    RoundedRectangleShape(cornerRadius: 1.5)
                        .fill(theme.editorColors.blue)
                        .frame(width: axis == .horizontal ? 3 : nil, height: axis == .vertical ? 3 : nil)
                        .accessibilityIdentifier("AdaEditor.ResizeHandle.Highlight")
                        .padding(axis == .horizontal ? .vertical : .horizontal, 4)
                        .allowsHitTesting(false)
                }
            }
            .drawingGroup()
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                        }
                        onResize(value.translation)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onResizeEnded()
                    }
            )
            .cursorShape(cursorShape)
            .onHover { isHovered = $0 }
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
