@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import AdaUtils
import Foundation
import Math
import Observation
import Synchronization
import Testing

@testable import AdaEditor

@Suite("AdaEngineStyle UI mock")
struct AdaEngineStyleUITests {
    @Test("build activity exposes live SwiftPM phases")
    func buildActivityExposesLiveSwiftPMSteps() {
        var activity = EditorBuildActivity(title: "Build Game")
        activity.consume("Planning build\n[3/12] Compiling Game Player.swift\n[11/12] Linking Game\n")

        #expect(activity.steps.map(\.title) == ["Preparing", "Planning build", "Compiling sources", "Linking"])
        #expect(activity.steps.dropLast().allSatisfy { $0.state == .completed })
        #expect(activity.currentStep?.title == "Linking")
        #expect(activity.currentStep?.detail == "Linking Game")
        #expect(activity.currentStep?.fractionCompleted == Float(11) / Float(12))

        activity.finish(succeeded: true)
        #expect(activity.currentStep?.title == "Completed")
        #expect(activity.currentStep?.state == .completed)
        #expect(activity.currentStep?.fractionCompleted == 1)
    }

    @Test("activity progress represents indexing and clamps determinate progress")
    @MainActor
    func activityProgressRepresentsIndexing() {
        let status = EditorWorkspaceStatus.preparing(
            SwiftPMWorkspaceProgress(
                phase: .indexingBuild,
                title: "Indexing Swift package",
                completedFileCount: 7,
                totalFileCount: 5,
                currentFile: "Player.swift"
            )
        )

        let activities = EditorActivityPresentation.events(
            workspaceStatus: status,
            previewStatus: .hidden,
            sourceControlIsRunning: false,
            sourceControlTitle: ""
        )

        #expect(activities.count == 1)
        #expect(activities.first?.kind == .indexing)
        #expect(activities.first?.detail == "Player.swift")
        #expect(activities.first?.fractionCompleted == 1)
        #expect(activities.first?.statusTitle == "Indexing Swift package · 100%")
    }

    @Test("activity progress keeps footer text compact")
    func activityProgressKeepsFooterTextCompact() {
        let activity = EditorActivityEvent(
            id: "indexing",
            kind: .indexing,
            title: "Indexing Swift package",
            detail: "/usr/bin/swift build --package-path Example",
            fractionCompleted: 0.61
        )

        #expect(activity.compactTitle == "Indexing · 61%")
    }

    @Test("activity progress supports build and concurrent source control events")
    @MainActor
    func activityProgressSupportsDifferentEvents() {
        let activities = EditorActivityPresentation.events(
            workspaceStatus: .running("Build Game"),
            previewStatus: .hidden,
            sourceControlIsRunning: true,
            sourceControlTitle: "Refreshing branches..."
        )

        #expect(activities.map(\.kind) == [.build, .sourceControl])
        #expect(activities.map(\.title) == ["Build Game", "Refreshing branches..."])
        #expect(activities.allSatisfy { $0.fractionCompleted == nil })
    }

    @Test("double Shift opens search only inside the shortcut interval")
    func doubleShiftSearchShortcutTiming() {
        var detector = EditorDoubleShiftDetector()

        #expect(detector.registerPress(at: 1) == false)
        #expect(detector.registerPress(at: 1.25) == true)
        #expect(detector.registerPress(at: 2) == false)
        #expect(detector.registerPress(at: 2.6) == false)
        #expect(detector.registerPress(at: 2.7, isRepeated: true) == false)
        #expect(detector.registerPress(at: 2.8) == true)
    }

    @Test("double Shift shortcut focuses the toolbar text field")
    @MainActor
    func doubleShiftSearchShortcutFocusesToolbarSearchField() throws {
        final class Model {
            var query = ""
        }

        let model = Model()
        let container = UIContainerView(
            rootView: VStack {
                TextField(
                    "Search Project Files",
                    text: Binding(get: { model.query }, set: { model.query = $0 })
                )
            }
            .accessibilityIdentifier(EditorTopToolbar.searchAccessibilityIdentifier)
        )
        container.frame = Rect(x: 0, y: 0, width: 320, height: 80)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        #expect(EditorSearchShortcutMonitor.shared.focusSearchField(in: [container]))
        let diagnostics = try container.uiLayoutDiagnostics(matching: nil, subtreeDepth: nil)
        #expect(diagnostics.textInputFocused)
        #expect(diagnostics.focusedNode?.nodeType.hasSuffix("TextFieldViewNode") == true)
    }

    @Test("tab context menu and middle-click support preserve select and close buttons")
    @MainActor
    func tabMiddleClickSupportPreservesButtons() throws {
        final class Counters {
            var selected = 0
            var closed = 0
            var middleClicked = 0
        }

        let counters = Counters()
        let container = UIContainerView(
            rootView: HStack(spacing: 0) {
                Button(action: { counters.selected += 1 }) {
                    Color.clear
                        .frame(width: 90, height: 32)
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.TestTab.Select")

                Button(action: { counters.closed += 1 }) {
                    Color.clear
                        .frame(width: 70, height: 32)
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.TestTab.Close")
            }
            .onMiddleClick {
                counters.middleClicked += 1
            }
            .contextMenu {
                Button("Close Tab") {}
            }
        )
        container.frame = Rect(x: 0, y: 0, width: 180, height: 40)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.TestTab.Select"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.TestTab.Close"))
        container.onMouseEvent(
            MouseEvent(
                window: RID(),
                button: .middle,
                mousePosition: Point(80, 16),
                phase: .began,
                modifierKeys: [],
                time: 0
            )
        )
        container.onMouseEvent(
            MouseEvent(
                window: RID(),
                button: .middle,
                mousePosition: Point(80, 16),
                phase: .ended,
                modifierKeys: [],
                time: 0.1
            )
        )

        #expect(counters.selected == 1)
        #expect(counters.closed == 1)
        #expect(counters.middleClicked == 1)
    }

    @Test("long tab keeps its close button inside the selectable cell")
    @MainActor
    func longTabKeepsCloseButtonInsideCell() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let app = AppWorlds(main: World(name: "AdaEditorTabTests"))
            RenderWorldPlugin().setup(in: app)
        }

        let document = EditorWorkbenchDocument.asset(
            EditorAssetDocument(
                id: "asset:TrustNoOneRuntimePlugin.swift",
                title: "TrustNoOneRuntimePlugin.swift",
                relativePath: "TrustNoOneRuntimePlugin.swift",
                absolutePath: nil,
                assetReference: nil,
                kind: .generic,
                fileExtension: "swift",
                byteCount: nil,
                modifiedAt: nil,
                errorMessage: nil
            )
        )
        let workbench = EditorWorkbenchViewModel(
            openDocuments: [document],
            activeDocumentID: document.id
        )
        let container = UIContainerView(
            rootView: EditorCenterWorkbench(
                viewModel: workbench,
                inspectorViewModel: EditorInspectorSidebarViewModel(),
                playModeState: .editing,
                scenePlayRuntime: nil,
                sceneResourceRootURL: nil,
                onPlayScene: nil,
                onStopScene: nil,
                onSceneEntitySelected: nil,
                onSourceHover: nil,
                onGoToDefinition: nil,
                onCompletionPosition: nil,
                onCompletionRequest: nil,
                onApplyCompletion: nil,
                onMoveCompletionSelection: nil,
                onAcceptCompletion: nil,
                onTextSelection: nil,
                onChatSelection: nil,
                sourceContextMenuItems: nil,
                onSelectDocument: nil,
                onRevealDocument: nil,
                onCopyDocumentPath: nil,
                onSelectPreview: nil,
                onRebuildPreview: nil,
                onHidePreview: nil,
                onShowPreviewBuildOutput: nil
            )
        )
        container.frame = Rect(x: 0, y: 0, width: 260, height: 120)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        let tab = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Tab.\(document.title)"))
        let close = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Tab.Close.\(document.id)"))
        #expect(close.absoluteFrame.minX >= tab.absoluteFrame.minX)
        #expect(close.absoluteFrame.maxX <= tab.absoluteFrame.maxX)

        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Tab.Close.\(document.id)"))
        #expect(workbench.openDocuments.isEmpty)
    }

    @Test("preview panel exposes a close button")
    @MainActor
    func previewPanelExposesCloseButton() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let app = AppWorlds(main: World(name: "AdaEditorPreviewPanelTests"))
            RenderWorldPlugin().setup(in: app)
        }

        let source = "@previewable @view class HUDView { func body() { Text(\"Preview\"); } }"
        let document = EditorTextDocument(
            id: "text:Sources/HUD.ada",
            title: "HUD.ada",
            relativePath: "Sources/HUD.ada",
            language: .ada,
            content: source
        )
        let declaration = EditorPreviewDeclaration(
            id: "HUDView",
            title: "HUD Preview",
            typeName: "HUDView",
            line: 1,
            kind: .adaScript
        )
        let workbench = EditorWorkbenchViewModel(
            openDocuments: [.text(document)],
            activeDocumentID: document.id,
            previewStatus: .available([declaration])
        )
        var hideCount = 0
        let container = UIContainerView(
            rootView: EditorCenterWorkbench(
                viewModel: workbench,
                inspectorViewModel: EditorInspectorSidebarViewModel(),
                playModeState: .editing,
                scenePlayRuntime: nil,
                sceneResourceRootURL: nil,
                onPlayScene: nil,
                onStopScene: nil,
                onSceneEntitySelected: nil,
                onSourceHover: nil,
                onGoToDefinition: nil,
                onCompletionPosition: nil,
                onCompletionRequest: nil,
                onApplyCompletion: nil,
                onMoveCompletionSelection: nil,
                onAcceptCompletion: nil,
                onTextSelection: nil,
                onChatSelection: nil,
                sourceContextMenuItems: nil,
                onSelectDocument: nil,
                onRevealDocument: nil,
                onCopyDocumentPath: nil,
                onSelectPreview: nil,
                onRebuildPreview: nil,
                onHidePreview: { hideCount += 1 },
                onShowPreviewBuildOutput: nil
            )
        )
        container.frame = Rect(x: 0, y: 0, width: 900, height: 600)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.PreviewPanel.Close"))

        #expect(hideCount == 1)
    }

    @Test("project search results use the editor viewport instead of the toolbar frame")
    func projectSearchResultsEscapeToolbarFrame() {
        let toolbarHeight = AdaEngineStyleLayoutSpec.topToolbarHeight
        let popupTop = EditorProjectSearchResultsLayout.topOffset(toolbarHeight: toolbarHeight)
        let popupHeight = EditorProjectSearchResultsLayout.height(itemCount: 3)
        let expectedPopupHeight =
            EditorProjectSearchResultsLayout.rowHeight * 3
            + EditorProjectSearchResultsLayout.rowSpacing * 2
            + EditorProjectSearchResultsLayout.padding * 2

        #expect(popupTop == toolbarHeight - EditorProjectSearchResultsLayout.padding)
        #expect(popupHeight == expectedPopupHeight)
        #expect(popupTop + popupHeight > toolbarHeight)
    }

    @Test("toolbar search remains centered independently of trailing controls")
    @MainActor
    func toolbarSearchRemainsCentered() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let app = AppWorlds(main: World(name: "AdaEditorToolbarTests"))
            RenderWorldPlugin().setup(in: app)
        }

        let size = Size(width: 1_280, height: AdaEngineStyleLayoutSpec.topToolbarHeight)
        let metrics = AdaEngineStyleLayoutMetrics(size: size)
        let container = UIContainerView(
            rootView: EditorTopToolbar(
                project: EditorProjectReference(name: "Example", path: "/tmp/Example"),
                isProjectSwitcherPresented: false,
                isRunDestinationMenuPresented: false,
                viewModel: EditorToolbarViewModel(),
                runDestination: .macOS,
                isRunEnabled: true,
                isStopEnabled: false,
                onToggleRunDestinationMenu: {},
                onToggleProjectSwitcher: {},
                onRun: {},
                onStop: {}
            )
            .environment(\.metrics, metrics)
        )
        container.frame = Rect(origin: .zero, size: size)
        container.bounds.size = size
        container.layoutIfNeeded()

        let search = try container.uiNode(matching: .accessibilityIdentifier(EditorTopToolbar.searchAccessibilityIdentifier))
        let projectSwitcher = try container.uiNode(matching: .accessibilityIdentifier(EditorTopToolbar.projectSwitcherAccessibilityIdentifier))
        #expect(abs(search.absoluteFrame.midX - size.width / 2) < 0.5)
        #expect(search.absoluteFrame.width == metrics.toolbarSearchWidth)
        #expect(projectSwitcher.absoluteFrame.minX >= metrics.toolbarWindowControlClearance)
        #expect(projectSwitcher.absoluteFrame.maxX < search.absoluteFrame.minX)
    }

    @Test("desktop grid dimensions match the requested IDE layout")
    func desktopGridDimensions() {
        #expect(AdaEngineStyleLayoutSpec.topToolbarHeight == 40)
        #expect(AdaEngineStyleLayoutSpec.toolStripWidth == 40)
        #expect(AdaEngineStyleLayoutSpec.panelSpacing == 8)
        #expect(AdaEngineStyleLayoutSpec.projectSidebarWidth == 260)
        #expect(AdaEngineStyleLayoutSpec.inspectorWidth == 300)
        #expect(AdaEngineStyleLayoutSpec.footerHeight == 24)
        #expect(AdaEngineStyleLayoutSpec.minimumWidth < AdaEngineStyleLayoutSpec.windowWidth)
        #expect(AdaEngineStyleLayoutSpec.minimumHeight < AdaEngineStyleLayoutSpec.windowHeight)
        #expect(AdaEngineStyleLayoutSpec.aiFlightBoxCompactWidth < AdaEngineStyleLayoutSpec.aiFlightBoxWidth)
    }

    @Test("layout metrics adapt to smaller windows")
    func layoutMetricsAdaptToSmallerWindows() {
        let desktop = AdaEngineStyleLayoutMetrics(size: Size(width: 1280, height: 820))
        let compact = AdaEngineStyleLayoutMetrics(size: Size(width: 700, height: 420))

        #expect(desktop.showsProjectSidebar)
        #expect(desktop.showsInspectorSidebar)
        #expect(!compact.showsProjectSidebar)
        #expect(!compact.showsInspectorSidebar)
        #expect(compact.toolbarSearchWidth < desktop.toolbarSearchWidth)
        #expect(compact.aiFlightBoxWidth <= compact.workbenchWidth)
        #expect(compact.aiFlightBoxHeight < desktop.aiFlightBoxHeight)
        #expect(compact.outputTabs.count < AdaEngineStyleContent.outputTabs.count)
        #expect(compact.toolbarWindowControlClearance == 60)
        #expect(!compact.showsToolbarSceneName)
        #expect(compact.toolbarRunDestinationWidth == 96)
        #expect(compact.toolbarRunControlsWidth == 64)
    }

    @Test("empty hierarchy fills its panel and stays top aligned")
    @MainActor
    func emptyHierarchyFillsPanel() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let app = AppWorlds(main: World(name: "EmptyHierarchyLayoutTests"))
            RenderWorldPlugin().setup(in: app)
        }
        let size = Size(width: 260, height: 700)
        let container = UIContainerView(
            rootView: EditorSceneHierarchySidebar(
                document: nil,
                onSelectEntity: { _ in },
                onToggleEntityExpanded: { _ in }
            )
        )
        container.frame = Rect(origin: .zero, size: size)
        container.bounds.size = size
        container.layoutIfNeeded()

        let hierarchy = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.SceneHierarchy"))
        let emptyState = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.SceneHierarchy.EmptyState"))

        #expect(hierarchy.absoluteFrame.height == size.height)
        #expect(emptyState.absoluteFrame.minY < 80)
        #expect(emptyState.absoluteFrame.maxY <= size.height)
    }

    @Test("scene hierarchy rows show icons separators selection and hover")
    @MainActor
    func sceneHierarchyRowsExposeVisualStates() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let app = AppWorlds(main: World(name: "SceneHierarchyRowTests"))
            RenderWorldPlugin().setup(in: app)
        }
        var model = EditorSceneModel.default(projectName: "HierarchyRows")
        let rootID = try #require(model.entities.first?.id)
        let selectedEntity = model.addEntity(name: "Colored sprite 01")
        model.addComponent(typeName: EditorBuiltInComponentType.sprite, to: selectedEntity.id)
        model.selectEntity(selectedEntity.id)
        let content = try model.encodedYAML()
        let document = EditorSceneDocument(
            id: "scene:hierarchy-rows",
            title: "HierarchyRows.ascn",
            relativePath: "Assets/Scenes/HierarchyRows.ascn",
            absolutePath: nil,
            content: content,
            lastSavedContent: content,
            isReadOnly: false,
            sceneModel: model,
            errorMessage: nil,
            isDirty: false,
            statusMessage: nil,
            loadSummary: EditorSceneFileLoader.summary(from: content)
        )
        var selectedEntityID: String?
        var addedChildParentID: String?
        var visibilityChange: (entityID: String, isEnabled: Bool)?
        var reparentedEntityIDs: (entity: String, parent: String)?
        var contextMenu: ContextMenuPresentation?
        ContextMenuPresentationCenter.present = { contextMenu = $0 }
        defer { ContextMenuPresentationCenter.present = nil }
        let container = UIContainerView(
            rootView: EditorSceneHierarchySidebar(
                document: document,
                onSelectEntity: { selectedEntityID = $0 },
                onToggleEntityExpanded: { _ in },
                onAddEntity: { addedChildParentID = $0 },
                onSetEntityEnabled: { entityID, isEnabled in visibilityChange = (entityID, isEnabled) },
                onReparentEntity: { entityID, parentID in
                    reparentedEntityIDs = (entityID, parentID)
                }
            )
        )
        container.frame = Rect(x: 0, y: 0, width: 320, height: 300)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        let selectedRow = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.SceneHierarchy.Row.\(selectedEntity.id)"))
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.SceneHierarchy.Icon.\(selectedEntity.id)"))
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.SceneHierarchy.Separator.\(selectedEntity.id)"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.SceneHierarchy.Visibility.\(selectedEntity.id)"))
        #expect(visibilityChange?.entityID == selectedEntity.id)
        #expect(visibilityChange?.isEnabled == false)

        #expect(selectedRow.absoluteFrame.height <= 36)

        let rootRow = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.SceneHierarchy.Row.\(rootID)"))
        container.uiReceivePassthroughMouseMoved(
            MouseEvent(
                window: RID(),
                button: .none,
                mousePosition: Point(x: rootRow.absoluteFrame.midX, y: rootRow.absoluteFrame.midY),
                phase: .changed,
                modifierKeys: [],
                time: 0
            )
        )
        container.layoutIfNeeded()

        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.SceneHierarchy.RowState.\(rootID).hovered"))

        let selectableRow = try container.uiNode(
            matching: .accessibilityIdentifier("AdaEditor.SceneHierarchy.Select.\(selectedEntity.id)")
        )
        _ = try container.uiTapNode(
            matching: .accessibilityIdentifier("AdaEditor.SceneHierarchy.Select.\(selectedEntity.id)")
        )
        #expect(selectedEntityID == selectedEntity.id)

        let selectedPoint = container.convert(
            Point(x: selectableRow.absoluteFrame.midX, y: selectableRow.absoluteFrame.midY),
            to: container.window
        )
        container.onMouseEvent(MouseEvent(window: RID(), button: .right, mousePosition: selectedPoint, phase: .began, modifierKeys: [], time: 0.02))
        let menuItems = contextMenu?.items.filter { !$0.isSeparator } ?? []
        #expect(
            menuItems.map(\.title) == [
                "Add Child",
                "Hide",
                "Rename",
                "Duplicate",
                "Copy",
                "Paste as Child",
                "Delete",
            ]
        )
        menuItems.first(where: { $0.title == "Add Child" })?.action?()
        #expect(addedChildParentID == selectedEntity.id)

        let rootPoint = container.convert(
            Point(x: rootRow.absoluteFrame.midX, y: rootRow.absoluteFrame.midY),
            to: container.window
        )
        container.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: selectedPoint, phase: .began, modifierKeys: [], time: 0.03))
        container.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: rootPoint, phase: .changed, modifierKeys: [], time: 0.04))
        container.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: rootPoint, phase: .ended, modifierKeys: [], time: 0.05))
        #expect(reparentedEntityIDs?.entity == selectedEntity.id)
        #expect(reparentedEntityIDs?.parent == rootID)

        contextMenu = nil
        container.onMouseEvent(
            MouseEvent(
                window: RID(),
                button: .right,
                mousePosition: Point(x: 290, y: 260),
                phase: .began,
                modifierKeys: [],
                time: 0.06
            )
        )
        #expect(contextMenu?.items.filter { !$0.isSeparator }.map(\.title) == ["Add", "Paste"])
        #expect(contextMenu?.items.first?.submenu.isEmpty == true)
        contextMenu?.items.first(where: { $0.title == "Add" })?.action?()
        #expect(addedChildParentID == rootID)

        menuItems.first(where: { $0.title == "Rename" })?.action?()
        container.layoutIfNeeded()
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.SceneHierarchy.RenameField.\(selectedEntity.id)"))
    }

    @Test("code completion popup remains inside the editor viewport")
    func codeCompletionPopupRemainsVisible() {
        let viewport = Size(width: 640, height: 320)
        let frame = EditorCompletionPopupLayout.frame(
            viewportSize: viewport,
            caretRect: Rect(x: 1_200, y: 2_000, width: 1.5, height: 18),
            itemCount: 8
        )

        #expect(frame.width == EditorCompletionPopupLayout.preferredWidth)
        #expect(frame.minX >= EditorCompletionPopupLayout.viewportInset)
        #expect(frame.minY >= EditorCompletionPopupLayout.viewportInset)
        #expect(frame.maxX <= viewport.width - EditorCompletionPopupLayout.viewportInset)
        #expect(frame.maxY <= viewport.height - EditorCompletionPopupLayout.viewportInset)
        #expect(frame.height == EditorCompletionPopupLayout.rowHeight * 8 + EditorCompletionPopupLayout.verticalPadding * 2)
    }

    @Test("code completion popup starts below a nearby caret")
    func codeCompletionPopupTracksCaret() {
        let frame = EditorCompletionPopupLayout.frame(
            viewportSize: Size(width: 900, height: 700),
            caretRect: Rect(x: 128, y: 72, width: 1.5, height: 18),
            itemCount: 3
        )

        #expect(frame.minX == 128)
        #expect(frame.minY == 90)
    }

    @Test("source hover popup stays inside the editor and prefers the space above the symbol")
    func sourceHoverPopupTracksSymbol() {
        let frame = EditorSourceHoverPopupLayout.frame(
            viewportSize: Size(width: 900, height: 700),
            hoveredRange: EditorSourceRange(
                start: EditorSourceLocation(line: 14, character: 12),
                end: EditorSourceLocation(line: 14, character: 20)
            ),
            fontSize: 12,
            description: "func dispatchEvent(_ event: Event) -> Bool\nDispatches an event to registered listeners."
        )

        #expect(frame.minX >= EditorSourceHoverPopupLayout.viewportInset)
        #expect(frame.minY >= EditorSourceHoverPopupLayout.viewportInset)
        #expect(frame.maxX <= 900 - EditorSourceHoverPopupLayout.viewportInset)
        #expect(frame.maxY <= 700 - EditorSourceHoverPopupLayout.viewportInset)
        #expect(frame.maxY < 18 + Float(14) * max(18, Float(12) * 1.45))
    }

    @Test("source hover presentation removes markdown code fences")
    func sourceHoverPresentationRemovesCodeFences() {
        let text = EditorSourceHoverPresentation.displayText(from: "```swift\nfunc update()\n```\nUpdates the scene.")

        #expect(text == "func update()\nUpdates the scene.")
    }

    @Test("source hover presentation applies syntax colors")
    @MainActor
    func sourceHoverPresentationAppliesSyntaxColors() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let app = AppWorlds(main: World(name: "AdaEditorSourceHoverTests"))
            RenderWorldPlugin().setup(in: app)
        }

        let text = "private func update(value: Int) -> Bool"
        let attributedText = EditorSourceHoverPresentation.attributedText(
            text,
            language: .swift,
            palette: .dark,
            font: .system(size: 11),
            keywordFont: .system(size: 11, weight: .bold)
        )
        let privateIndex = try #require(text.range(of: "private")?.lowerBound)
        let intIndex = try #require(text.range(of: "Int")?.lowerBound)

        #expect(attributedText.attributes(at: privateIndex).foregroundColor == EditorCodeColorPalette.dark.keyword)
        #expect(attributedText.attributes(at: intIndex).foregroundColor == EditorCodeColorPalette.dark.type)
    }

    @Test("completion presentation stays on one line and caps visible rows")
    func completionPresentationStaysOnOneLine() {
        let item = EditorCompletionItem(
            label: "withUnsafeBufferPointer(\n  body: (UnsafeBufferPointer<Element>) throws -> Result\n)",
            detail: "Array method\nResult",
            insertText: "withUnsafeBufferPointer",
            replacementRange: nil,
            sortText: nil,
            kind: .method
        )
        let label = EditorCompletionPresentation.label(for: item)
        let detail = EditorCompletionPresentation.detail(for: item)
        let frame = EditorCompletionPopupLayout.frame(
            viewportSize: Size(width: 900, height: 700),
            caretRect: Rect(x: 128, y: 36, width: 1.5, height: 18),
            itemCount: 40
        )

        #expect(!label.contains("\n"))
        #expect(detail?.contains("\n") == false)
        #expect(label.count <= 34)
        #expect(frame.height == EditorCompletionPopupLayout.rowHeight * 10 + EditorCompletionPopupLayout.verticalPadding * 2)
    }

    @Test("preview split width stays resizable while preserving editor space")
    func previewSplitWidthIsResizable() {
        #expect(EditorPreviewSplitLayout.previewWidth(requestedWidth: 500, availableWidth: 1_000) == 500)
        #expect(EditorPreviewSplitLayout.previewWidth(requestedWidth: 100, availableWidth: 1_000) == 260)
        #expect(EditorPreviewSplitLayout.previewWidth(requestedWidth: 900, availableWidth: 1_000) == 672)
        #expect(EditorPreviewSplitLayout.previewWidth(requestedWidth: 360, availableWidth: 500) == 172)
    }

    @Test("workspace reserves sidebars and output panel before sizing the scene viewport")
    func workspaceReservesPanelsBeforeSizingViewport() {
        let layout = EditorWorkspaceLayout(
            size: Size(width: 1_200, height: 700),
            showsLeftPanel: true,
            showsRightPanel: true,
            showsBottomPanel: true,
            requestedLeftPanelWidth: 260,
            requestedRightPanelWidth: 300,
            requestedBottomPanelHeight: 180,
            fallbackLeftPanelWidth: 260,
            fallbackRightPanelWidth: 300
        )

        #expect(layout.leftPanelWidth == 260)
        #expect(layout.mainPanelWidth == 624)
        #expect(layout.rightPanelWidth == 300)
        #expect(layout.mainPanelHeight == 512)
        #expect(layout.bottomPanelHeight == 180)
    }

    @Test("workspace lets sidebars consume the available width without artificial limits")
    func workspaceSidebarsCanConsumeAvailableWidth() {
        let layout = EditorWorkspaceLayout(
            size: Size(width: 936, height: 620),
            showsLeftPanel: true,
            showsRightPanel: true,
            showsBottomPanel: true,
            requestedLeftPanelWidth: 600,
            requestedRightPanelWidth: 600,
            requestedBottomPanelHeight: 520,
            fallbackLeftPanelWidth: 260,
            fallbackRightPanelWidth: 300
        )

        #expect(abs(layout.leftPanelWidth - 460) < 0.001)
        #expect(abs(layout.rightPanelWidth - 460) < 0.001)
        #expect(layout.mainPanelWidth == 0)
        #expect(abs(layout.mainPanelHeight - EditorWorkspaceLayout.minimumMainPanelHeight) < 0.001)
    }

    @Test("workspace does not impose an artificial maximum on the left sidebar")
    func workspaceLeftSidebarHasNoArtificialMaximum() {
        let layout = EditorWorkspaceLayout(
            size: Size(width: 1_800, height: 700),
            showsLeftPanel: true,
            showsRightPanel: false,
            showsBottomPanel: false,
            requestedLeftPanelWidth: 900,
            requestedRightPanelWidth: 300,
            requestedBottomPanelHeight: 180,
            fallbackLeftPanelWidth: 260,
            fallbackRightPanelWidth: 300
        )

        #expect(layout.leftPanelWidth == 900)
        #expect(layout.mainPanelWidth == 892)
    }

    @Test("workspace does not impose an artificial maximum on the right sidebar")
    func workspaceRightSidebarHasNoArtificialMaximum() {
        let layout = EditorWorkspaceLayout(
            size: Size(width: 1_800, height: 700),
            showsLeftPanel: false,
            showsRightPanel: true,
            showsBottomPanel: false,
            requestedLeftPanelWidth: 260,
            requestedRightPanelWidth: 1_200,
            requestedBottomPanelHeight: 180,
            fallbackLeftPanelWidth: 260,
            fallbackRightPanelWidth: 300
        )

        #expect(layout.rightPanelWidth == 1_200)
        #expect(layout.mainPanelWidth == 592)
    }

    @Test("workspace expands the editor viewport into hidden sidebar slots")
    func workspaceExpandsViewportWhenSidebarsAreHidden() {
        let visible = EditorWorkspaceLayout(
            size: Size(width: 1_200, height: 700),
            showsLeftPanel: true,
            showsRightPanel: true,
            showsBottomPanel: false,
            requestedLeftPanelWidth: 260,
            requestedRightPanelWidth: 300,
            requestedBottomPanelHeight: 180,
            fallbackLeftPanelWidth: 260,
            fallbackRightPanelWidth: 300
        )
        let leftHidden = EditorWorkspaceLayout(
            size: Size(width: 1_200, height: 700),
            showsLeftPanel: false,
            showsRightPanel: true,
            showsBottomPanel: false,
            requestedLeftPanelWidth: 260,
            requestedRightPanelWidth: 300,
            requestedBottomPanelHeight: 180,
            fallbackLeftPanelWidth: 260,
            fallbackRightPanelWidth: 300
        )
        let rightHidden = EditorWorkspaceLayout(
            size: Size(width: 1_200, height: 700),
            showsLeftPanel: true,
            showsRightPanel: false,
            showsBottomPanel: false,
            requestedLeftPanelWidth: 260,
            requestedRightPanelWidth: 300,
            requestedBottomPanelHeight: 180,
            fallbackLeftPanelWidth: 260,
            fallbackRightPanelWidth: 300
        )
        let hidden = EditorWorkspaceLayout(
            size: Size(width: 1_200, height: 700),
            showsLeftPanel: false,
            showsRightPanel: false,
            showsBottomPanel: false,
            requestedLeftPanelWidth: 260,
            requestedRightPanelWidth: 300,
            requestedBottomPanelHeight: 180,
            fallbackLeftPanelWidth: 260,
            fallbackRightPanelWidth: 300
        )

        #expect(visible.mainPanelWidth == 624)
        #expect(leftHidden.leftPanelWidth == 0)
        #expect(leftHidden.mainPanelWidth == 892)
        #expect(rightHidden.rightPanelWidth == 0)
        #expect(rightHidden.mainPanelWidth == 932)
        #expect(hidden.leftPanelWidth == 0)
        #expect(hidden.mainPanelWidth == 1_200)
        #expect(hidden.rightPanelWidth == 0)
    }

    @Test("all required IDE regions expose reference labels")
    func requiredReferenceLabels() {
        #expect(AdaEngineStyleContent.topToolbarLabels.contains("Search Everywhere"))
        #expect(AdaEngineStyleContent.topToolbarLabels.contains("main_scene"))
        #expect(!AdaEngineStyleContent.topToolbarLabels.contains("Hot Reload"))
        #expect(AdaEngineStyleContent.leftTopSidebarTools.map(\.title) == ["File Tree", "Entity Tree", "Source Control"])
        #expect(AdaEngineStyleContent.leftBottomSidebarTools.map(\.title) == ["Logs", "Build", "Debug", "Animator"])
        #expect(AdaEngineStyleContent.rightSidebarTools.map(\.title) == ["Agent Chat", "Inspector", "Project Dependencies", "Swift Package Tasks", "Plugins", "Project Settings"])
        #expect(AdaEngineStyleContent.projectTreeItems == ["src", "EngineLoop.ada", "Renderer.ada", "Main.ascn"])
        #expect(AdaEngineStyleContent.editorTabs.contains("Main.ascn"))
        #expect(AdaEngineStyleContent.outputTabs == ["Problems", "Build", "Tests", "References", "Output"])
    }

    @Test("sidebar tools use renderable compact glyphs")
    func sidebarToolsUseRenderableCompactGlyphs() {
        let allIcons =
            AdaEngineStyleContent.leftTopSidebarTools
            + AdaEngineStyleContent.leftBottomSidebarTools
            + AdaEngineStyleContent.rightSidebarTools
        let iconCodepoints = allIcons.compactMap { $0.icon.unicodeScalars.first?.value }

        #expect(iconCodepoints.count == allIcons.count)
        #expect(Set(iconCodepoints).isSubset(of: Set(AdaEditorMaterialSymbolFont.codepoints)))
        #expect(allIcons.allSatisfy { $0.icon.unicodeScalars.count == 1 })
    }

    @Test("settings sections use renderable Material Symbols")
    func settingsSectionsUseRenderableMaterialSymbols() {
        let iconCodepoints = EditorSettingsSection.allCases.compactMap { $0.icon.unicodeScalars.first?.value }

        #expect(iconCodepoints.count == EditorSettingsSection.allCases.count)
        #expect(Set(iconCodepoints).isSubset(of: Set(AdaEditorMaterialSymbolFont.codepoints)))
    }

    @Test("project tree uses renderable Material Symbols")
    func projectTreeUsesRenderableMaterialSymbols() {
        let iconCodepoints = EditorProjectTreeIcon.allSymbols.compactMap { $0.unicodeScalars.first?.value }

        #expect(iconCodepoints.count == EditorProjectTreeIcon.allSymbols.count)
        #expect(Set(iconCodepoints).isSubset(of: Set(AdaEditorMaterialSymbolFont.codepoints)))
        #expect(EditorProjectTreeIcon.allSymbols.allSatisfy { $0.unicodeScalars.count == 1 })
    }

    @Test("scene hierarchy icons are renderable Material Symbols")
    func sceneHierarchyIconsAreRenderableMaterialSymbols() {
        let iconCodepoints = EditorSceneHierarchyIcon.allSymbols.compactMap { $0.unicodeScalars.first?.value }

        #expect(iconCodepoints.count == EditorSceneHierarchyIcon.allSymbols.count)
        #expect(Set(iconCodepoints).isSubset(of: Set(AdaEditorMaterialSymbolFont.codepoints)))
    }

    @Test("AI flight box and inspector include requested interactive copy")
    func aiFlightBoxAndInspectorCopy() {
        #expect(AdaEngineStyleContent.aiTitle == "Ada Intelligence")
        #expect(AdaEngineStyleContent.aiHint == "⌘L to Focus")
        #expect(AdaEngineStyleContent.aiPlaceholder == "Ask to generate logic, optimize shaders, or place objects...")
        #expect(AdaEngineStyleContent.aiChips == ["Refactor current scene", "Optimize render batches", "Auto-light"])
        #expect(AdaEngineStyleContent.inspectorScript == "DynamicBouncer.ada")
        #expect(AdaEngineStyleContent.inspectorScriptDescription == "Object bounces on contact")
    }

    @Test("status and output panel include required runtime messages")
    @MainActor
    func statusAndOutputMessages() {
        #expect(AdaEngineStyleContent.logLines.contains { $0.contains("Ada Engine initialized") })
        #expect(AdaEngineStyleContent.logLines.contains { $0.contains("AI optimization note") })
        let footer = EditorFooterViewModel()
        #expect(footer.leftItems.isEmpty)
        #expect(footer.rightItems.isEmpty)
        footer.setWorkspaceFooterTitle("Preparing")
        footer.setWorkspaceFooterTitle("Ready")
        footer.setSourceControlFooterTitle("Git: main")
        footer.setSourceControlFooterTitle("Git: feature*")
        #expect(footer.leftItems == ["Workspace: Ready"])
        #expect(footer.rightItems == ["Git: feature*"])
        footer.setSourceControlFooterTitle(nil)
        #expect(footer.rightItems.isEmpty)
    }

    @Test("output lines cap pathological compiler invocations")
    func outputLinesCapPathologicalCompilerInvocations() {
        let shortLine = EditorWorkspaceLogLine(text: "error: missing symbol")
        let longLine = EditorWorkspaceLogLine(text: String(repeating: "x", count: EditorWorkspaceLogLine.maximumTextLength + 500))

        #expect(shortLine.text == "error: missing symbol")
        #expect(longLine.text.count < EditorWorkspaceLogLine.maximumTextLength + 50)
        #expect(longLine.text.hasSuffix("… [truncated]"))
    }

    @Test("output buffer appends chunks atomically and preserves its cap")
    func outputBufferAppendsChunksAndPreservesCap() {
        let existing = (0..<390).map { EditorWorkspaceLogLine(id: "old-\($0)", text: "old \($0)") }
        let appended = (0..<20).map { "new \($0)" }

        let result = EditorWorkspaceLogBuffer.appending(appended, to: existing)

        #expect(result.count == EditorWorkspaceLogBuffer.maximumLineCount)
        #expect(result.first?.id == "old-10")
        #expect(result.suffix(20).map(\.text) == appended)
    }

    @Test("repeated source diagnostics do not invalidate an unchanged problem list")
    @MainActor
    func repeatedSourceDiagnosticsDoNotInvalidateProblems() {
        let diagnostic = EditorDiagnostic(
            filePath: "/tmp/Game/Sources/Game/main.swift",
            range: EditorSourceRange(
                start: EditorSourceLocation(line: 2, character: 4),
                end: EditorSourceLocation(line: 2, character: 8)
            ),
            severity: .error,
            message: "Unknown symbol",
            source: "sourcekit-lsp"
        )
        let viewModel = EditorViewModel(problems: [])
        let problemListChanges = Mutex(0)

        withObservationTracking {
            _ = viewModel.problems
        } onChange: {
            problemListChanges.withLock { $0 += 1 }
        }
        viewModel.receiveSourceDiagnostics([diagnostic], uri: "file:///tmp/Game/Sources/Game/main.swift")
        #expect(problemListChanges.withLock { $0 } == 1)

        withObservationTracking {
            _ = viewModel.problems
        } onChange: {
            problemListChanges.withLock { $0 += 1 }
        }
        viewModel.receiveSourceDiagnostics([diagnostic], uri: "file:///tmp/Game/Sources/Game/main.swift")
        #expect(problemListChanges.withLock { $0 } == 1)
    }

    @Test("build diagnostics are attached to open source documents")
    @MainActor
    func buildDiagnosticsAttachToOpenDocuments() throws {
        let filePath = "/tmp/Game/Sources/Game/main.swift"
        let document = EditorTextDocument(
            id: "text:Sources/Game/main.swift",
            title: "main.swift",
            relativePath: "Sources/Game/main.swift",
            absolutePath: filePath,
            language: .swift,
            content: "let value = missing"
        )
        let diagnostic = EditorDiagnostic(
            filePath: filePath,
            range: EditorSourceRange(
                start: EditorSourceLocation(line: 0, character: 12),
                end: EditorSourceLocation(line: 0, character: 19)
            ),
            severity: .error,
            message: "cannot find 'missing' in scope",
            source: "swift"
        )
        let viewModel = EditorViewModel(
            workbench: EditorWorkbenchViewModel(openDocuments: [.text(document)], activeDocumentID: document.id)
        )

        viewModel.replaceBuildDiagnostics(with: [diagnostic])

        guard case let .text(updatedDocument)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected active text document")
            return
        }
        #expect(updatedDocument.diagnostics == [diagnostic])
    }

    @Test("repeated diagnostics from multiple files preserve problem order and observation state")
    @MainActor
    func repeatedMultiFileSourceDiagnosticsDoNotReorderProblems() {
        let firstDiagnostic = EditorDiagnostic(
            filePath: "/tmp/Game/Sources/Game/First.swift",
            range: EditorSourceRange(
                start: EditorSourceLocation(line: 1, character: 0),
                end: EditorSourceLocation(line: 1, character: 4)
            ),
            severity: .warning,
            message: "First warning",
            source: "sourcekit-lsp"
        )
        let secondDiagnostic = EditorDiagnostic(
            filePath: "/tmp/Game/Sources/Game/Second.swift",
            range: EditorSourceRange(
                start: EditorSourceLocation(line: 2, character: 0),
                end: EditorSourceLocation(line: 2, character: 4)
            ),
            severity: .error,
            message: "Second error",
            source: "sourcekit-lsp"
        )
        let viewModel = EditorViewModel(problems: [])
        viewModel.receiveSourceDiagnostics([firstDiagnostic], uri: "file:///tmp/Game/Sources/Game/First.swift")
        viewModel.receiveSourceDiagnostics([secondDiagnostic], uri: "file:///tmp/Game/Sources/Game/Second.swift")
        let problemListChanges = Mutex(0)

        withObservationTracking {
            _ = viewModel.problems
        } onChange: {
            problemListChanges.withLock { $0 += 1 }
        }
        viewModel.receiveSourceDiagnostics([firstDiagnostic], uri: "file:///tmp/Game/Sources/Game/First.swift")
        viewModel.receiveSourceDiagnostics([secondDiagnostic], uri: "file:///tmp/Game/Sources/Game/Second.swift")

        #expect(problemListChanges.withLock { $0 } == 0)
        #expect(viewModel.problems == [firstDiagnostic, secondDiagnostic])
    }

    @Test("workspace failure status keeps build output out of compact chrome")
    func workspaceFailureStatusKeepsBuildOutputOutOfCompactChrome() {
        let buildOutput = String(repeating: "swift compiler diagnostic ", count: 500)

        #expect(EditorWorkspaceStatus.failed(buildOutput).title == "Failed")
    }

    @Test("hot reload state exposes compact toolbar and footer labels")
    func hotReloadStateLabels() {
        let ready = EditorHotReloadState(isEnabled: true, watchedPathCount: 3, lastReloadedPath: nil, errorMessage: nil)
        let reloaded = EditorHotReloadState(isEnabled: true, watchedPathCount: 3, lastReloadedPath: "main.swift", errorMessage: nil)
        let failed = EditorHotReloadState(isEnabled: false, watchedPathCount: 3, lastReloadedPath: nil, errorMessage: "Permission denied")

        #expect(ready.toolbarTitle == "Hot Reload")
        #expect(ready.footerTitle == "Hot Reload: 3 paths")
        #expect(reloaded.toolbarTitle == "Reloaded")
        #expect(reloaded.footerTitle == "Hot Reload: main.swift")
        #expect(failed.toolbarTitle == "Hot Reload Failed")
        #expect(failed.footerTitle == "Hot Reload: Permission denied")
    }

    @Test("hot reload watch paths use project metadata and ignore missing directories")
    func hotReloadWatchPathsUseProjectMetadata() throws {
        let rootURL = try makeAdaEngineStyleUITemporaryDirectory(named: "EditorHotReloadPaths")
        defer { removeAdaEngineStyleUITemporaryDirectory(rootURL) }

        let sourcesURL = rootURL.appendingPathComponent("GameSources", isDirectory: true)
        let assetsURL = rootURL.appendingPathComponent("GameAssets", isDirectory: true)
        let metadataURL = rootURL.appendingPathComponent(ProjectSystem.metadataDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)

        let metadata = AdaProject(
            schemaVersion: ProjectSystem.currentSchemaVersion,
            paths: AdaProjectPaths(sources: "GameSources", assets: "GameAssets")
        )
        let urls = EditorHotReloadConfiguration.watchedDirectoryURLs(forProjectAt: rootURL, metadata: metadata)
            .map(\.path)

        #expect(
            urls == [
                sourcesURL.resolvingSymlinksInPath().path,
                assetsURL.resolvingSymlinksInPath().path,
                metadataURL.resolvingSymlinksInPath().path,
            ]
        )
    }

    @Test("hot reload watch paths deduplicate matching source and asset directories")
    func hotReloadWatchPathsDeduplicateDirectories() throws {
        let rootURL = try makeAdaEngineStyleUITemporaryDirectory(named: "EditorHotReloadDeduplicate")
        defer { removeAdaEngineStyleUITemporaryDirectory(rootURL) }

        let sharedURL = rootURL.appendingPathComponent("Sources", isDirectory: true)
        let metadataURL = rootURL.appendingPathComponent(ProjectSystem.metadataDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: sharedURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)

        let metadata = AdaProject(
            schemaVersion: ProjectSystem.currentSchemaVersion,
            paths: AdaProjectPaths(sources: "Sources", assets: "Sources")
        )
        let urls = EditorHotReloadConfiguration.watchedDirectoryURLs(forProjectAt: rootURL, metadata: metadata)
            .map(\.path)

        #expect(
            urls == [
                sharedURL.resolvingSymlinksInPath().path,
                metadataURL.resolvingSymlinksInPath().path,
            ]
        )
    }

    @Test("editor theme exposes AdaUI theme tokens")
    func editorThemeExposesAdaUIThemeTokens() {
        var theme = Theme.adaEditor
        let defaultColors = theme.editorColors

        #expect(defaultColors == EditorThemeColors.dark)
        #expect(defaultColors.background == Color(red: 30 / 255, green: 31 / 255, blue: 34 / 255))
        #expect(defaultColors.text == Color(red: 223 / 255, green: 225 / 255, blue: 229 / 255))

        var overriddenColors = defaultColors
        overriddenColors.blue = .green
        theme.editorColors = overriddenColors

        #expect(theme.editorColors.blue == .green)
        #expect(theme.editorColors.background == defaultColors.background)
    }

    @Test("editor view model exposes observable editor state defaults")
    @MainActor
    func editorViewModelDefaults() {
        let viewModel = EditorViewModel()

        #expect(viewModel.toolbar.sceneName == "main_scene")
        #expect(viewModel.toolStrip.activeLeftTopTool == "fileTree")
        #expect(viewModel.toolStrip.activeLeftBottomTool == "logs")
        #expect(viewModel.toolStrip.activeRightTool == "agentChat")
        #expect(!viewModel.showRightPanel)
        #expect(!viewModel.isRightToolPresented(AdaEngineStyleContent.rightSidebarTools[0]))
        #expect(viewModel.toolStrip.leftTopTools == AdaEngineStyleContent.leftTopSidebarTools)
        #expect(viewModel.toolStrip.leftBottomTools == AdaEngineStyleContent.leftBottomSidebarTools)
        #expect(viewModel.toolStrip.leftBottomTools.contains { $0.identifier == "animator" })
        #expect(viewModel.toolStrip.rightTools == AdaEngineStyleContent.rightSidebarTools)
        #expect(viewModel.projectSidebar.items.map(\.title) == AdaEngineStyleContent.projectTreeItems)
        #expect(viewModel.workbench.activeEditorTab == "Main.ascn")
        #expect(viewModel.workbench.activeOutputTab == "Problems")
        #expect(viewModel.workbench.openDocuments.map(\.title) == AdaEngineStyleContent.editorTabs)
        #expect(viewModel.workbench.codeColorPalette == EditorCodeColorPalette.dark)
        #expect(viewModel.inspectorSidebar.scriptName == AdaEngineStyleContent.inspectorScript)
        #expect(viewModel.footer.rightItems.isEmpty)
        #expect(viewModel.showsDebugOverlay == nil)
        #expect(viewModel.playModeState == .editing)
    }

    @Test("editor view model mutates interaction state")
    @MainActor
    func editorViewModelMutatesInteractionState() {
        let viewModel = EditorViewModel()

        viewModel.toolbar.searchText = "Renderer"
        viewModel.toolStrip.selectRightTool(AdaEngineStyleContent.rightSidebarTools[5])
        viewModel.toolStrip.selectLeftBottomTool(AdaEngineStyleContent.leftBottomSidebarTools[0])
        viewModel.selectOutputTab("Terminal")
        viewModel.workbench.aiPrompt = "Generate a platformer controller"
        viewModel.workbench.hoveredChip = AdaEngineStyleContent.aiChips.first
        viewModel.toggleDebugOverlay(.layoutBounds)

        #expect(viewModel.toolbar.searchText == "Renderer")
        #expect(viewModel.toolStrip.activeRightTool == "projectSettings")
        #expect(viewModel.toolStrip.activeLeftTopTool == "fileTree")
        #expect(viewModel.toolStrip.activeLeftBottomTool == "logs")
        #expect(viewModel.activeOutputTab == "Terminal")
        #expect(viewModel.workbench.activeOutputTab == "Terminal")
        #expect(viewModel.workbench.aiPrompt == "Generate a platformer controller")
        #expect(viewModel.workbench.hoveredChip == "Refactor current scene")
        #expect(viewModel.footer.leftItems.isEmpty)
        #expect(viewModel.showsDebugOverlay == .layoutBounds)

        viewModel.buildActivity = EditorBuildActivity(title: "Build")
        viewModel.clearOutput()
        #expect(viewModel.outputLines.isEmpty)
        #expect(viewModel.buildActivity?.title == "Build")
    }

    @Test("editor play mode runs active scene document from memory")
    @MainActor
    func editorPlayModeRunsActiveSceneDocumentFromMemory() throws {
        let viewModel = EditorViewModel()
        let sceneDocument = try #require(viewModel.workbench.activeSceneDocument)

        var editedDocument = sceneDocument
        editedDocument.content = SceneDocumentFormat.defaultSceneYAML(projectName: "UnsavedPlayScene")
        editedDocument.sceneModel = EditorSceneFileLoader.model(from: editedDocument.content)
        editedDocument.loadSummary = EditorSceneFileLoader.summary(from: editedDocument.content)
        editedDocument.isDirty = true
        viewModel.workbench.replaceSceneDocument(editedDocument)

        viewModel.runActiveSceneInEditor()

        #expect(viewModel.playModeState == .playing(sceneDocumentID: editedDocument.id, title: editedDocument.title))
        #expect(viewModel.workspaceStatus == .running("Play \(editedDocument.title)"))

        viewModel.stopPlayMode()
        #expect(viewModel.playModeState == .editing)
        #expect(viewModel.workspaceStatus == .ready)
    }

    @Test("editor play mode falls back to startup scene when active document is not a scene")
    @MainActor
    func editorPlayModeFallsBackToStartupScene() throws {
        let rootURL = try makeAdaEngineStyleUITemporaryDirectory(named: "EditorPlayStartupScene")
        defer { removeAdaEngineStyleUITemporaryDirectory(rootURL) }

        try createPlayableProject(at: rootURL, sceneName: "StartupPlayScene")
        let project = EditorProjectReference(name: "EditorPlayStartupScene", path: rootURL.path)
        let viewModel = EditorViewModel(project: project)
        viewModel.workbench.selectDocument(id: "text:src/EngineLoop.ada")

        viewModel.runActiveSceneInEditor()

        #expect(viewModel.playModeState == .playing(sceneDocumentID: "scene:Assets/Scenes/Main.ascn", title: "Main.ascn"))
        let activeScene = try #require(viewModel.workbench.activeSceneDocument)
        #expect(activeScene.relativePath == "Assets/Scenes/Main.ascn")
        #expect(activeScene.content.contains("StartupPlayScene"))
    }

    @Test("editor play mode reports missing startup scene")
    @MainActor
    func editorPlayModeReportsMissingStartupScene() throws {
        let rootURL = try makeAdaEngineStyleUITemporaryDirectory(named: "EditorPlayMissingStartupScene")
        defer { removeAdaEngineStyleUITemporaryDirectory(rootURL) }

        try createPlayableProject(at: rootURL, sceneName: "MissingStartupScene")
        try FileManager.default.removeItem(at: rootURL.appendingPathComponent(SceneDocumentFormat.defaultScenePath, isDirectory: false))

        let project = EditorProjectReference(name: "EditorPlayMissingStartupScene", path: rootURL.path)
        let viewModel = EditorViewModel(project: project)
        viewModel.workbench.selectDocument(id: "text:src/EngineLoop.ada")

        viewModel.runActiveSceneInEditor()

        #expect(viewModel.playModeState == .failed("Startup scene not found: Assets/Scenes/Main.ascn"))
        #expect(viewModel.workspaceStatus == .failed("Startup scene not found: Assets/Scenes/Main.ascn"))
    }

    @Test("inspector vector axis binding updates only the selected component")
    @MainActor
    func inspectorVectorAxisBindingUpdatesOnlySelectedComponent() {
        let viewModel = EditorInspectorSidebarViewModel()
        let positionField = EditorComponentField(key: "position", label: "Position", kind: .vector3)
        var appliedValue = ""

        viewModel.updateComponentField = { _, _, value in
            appliedValue = value
        }
        viewModel.selectEntity(
            EditorInspectorSidebarViewModel.SelectedEntity(
                editorID: "entity-1",
                name: "Player",
                componentNames: [EditorBuiltInComponentType.transform],
                transformFields: [EditorInspectorSidebarViewModel.TransformField(field: positionField, value: "1, 2, 3")],
                components: [
                    EditorInspectorSidebarViewModel.ComponentSection(
                        typeName: EditorBuiltInComponentType.transform,
                        displayName: "Transform",
                        fields: [
                            EditorInspectorSidebarViewModel.ComponentField(
                                typeName: EditorBuiltInComponentType.transform,
                                field: positionField,
                                value: "1, 2, 3"
                            )
                        ],
                        canRemove: false
                    )
                ],
                addableComponents: [],
                gizmo: nil,
                hasExplicitGizmo: false
            )
        )

        let yAxis = viewModel.componentVectorAxisBinding(typeName: EditorBuiltInComponentType.transform, field: positionField, axisIndex: 1)
        #expect(yAxis.wrappedValue == "2")

        yAxis.wrappedValue = "20"

        #expect(appliedValue == "1, 20, 3")
        #expect(viewModel.componentVectorAxisBinding(typeName: EditorBuiltInComponentType.transform, field: positionField, axisIndex: 0).wrappedValue == "1")
        #expect(viewModel.componentVectorAxisBinding(typeName: EditorBuiltInComponentType.transform, field: positionField, axisIndex: 1).wrappedValue == "20")
        #expect(viewModel.componentVectorAxisBinding(typeName: EditorBuiltInComponentType.transform, field: positionField, axisIndex: 2).wrappedValue == "3")
    }

    @Test("inspector vector axis binding keeps invalid drafts without clobbering model values")
    @MainActor
    func inspectorVectorAxisBindingKeepsInvalidDrafts() {
        let viewModel = EditorInspectorSidebarViewModel()
        let positionField = EditorComponentField(key: "position", label: "Position", kind: .vector3)
        var appliedValues: [String] = []

        viewModel.updateComponentField = { _, _, value in
            appliedValues.append(value)
        }
        viewModel.selectEntity(
            EditorInspectorSidebarViewModel.SelectedEntity(
                editorID: "entity-1",
                name: "Player",
                componentNames: [EditorBuiltInComponentType.transform],
                transformFields: [EditorInspectorSidebarViewModel.TransformField(field: positionField, value: "1, 2, 3")],
                components: [
                    EditorInspectorSidebarViewModel.ComponentSection(
                        typeName: EditorBuiltInComponentType.transform,
                        displayName: "Transform",
                        fields: [
                            EditorInspectorSidebarViewModel.ComponentField(
                                typeName: EditorBuiltInComponentType.transform,
                                field: positionField,
                                value: "1, 2, 3"
                            )
                        ],
                        canRemove: false
                    )
                ],
                addableComponents: [],
                gizmo: nil,
                hasExplicitGizmo: false
            )
        )

        let yAxis = viewModel.componentVectorAxisBinding(typeName: EditorBuiltInComponentType.transform, field: positionField, axisIndex: 1)
        yAxis.wrappedValue = ""
        #expect(yAxis.wrappedValue.isEmpty)
        #expect(appliedValues.isEmpty)
        #expect(viewModel.componentVectorAxisBinding(typeName: EditorBuiltInComponentType.transform, field: positionField, axisIndex: 0).wrappedValue == "1")
        #expect(viewModel.componentVectorAxisBinding(typeName: EditorBuiltInComponentType.transform, field: positionField, axisIndex: 2).wrappedValue == "3")

        yAxis.wrappedValue = "-4.5"
        #expect(yAxis.wrappedValue == "-4.5")
        #expect(appliedValues == ["1, -4.5, 3"])
    }

    @Test("sidebar toolstrip toggles visible panels by region")
    @MainActor
    func sidebarToolstripTogglesVisiblePanelsByRegion() {
        let viewModel = EditorViewModel()
        #expect(!viewModel.toolStrip.leftTopTools.contains { $0.identifier == "entityTree" })
        let fileTree = AdaEngineStyleContent.leftTopSidebarTools[0]
        let build = AdaEngineStyleContent.leftBottomSidebarTools[1]
        let inspector = AdaEngineStyleContent.rightSidebarTools[1]
        let settings = AdaEngineStyleContent.rightSidebarTools[5]

        #expect(viewModel.showLeftPanel)
        #expect(viewModel.isLeftTopToolPresented(fileTree))
        viewModel.activateLeftTopTool(fileTree)
        #expect(!viewModel.showLeftPanel)
        #expect(!viewModel.isLeftTopToolPresented(fileTree))
        viewModel.activateLeftTopTool(fileTree)
        #expect(viewModel.showLeftPanel)
        #expect(viewModel.isLeftTopToolPresented(fileTree))

        viewModel.activateLeftBottomTool(build)
        #expect(viewModel.showBottomPanel)
        #expect(viewModel.toolStrip.activeLeftTopTool == "fileTree")
        #expect(viewModel.toolStrip.activeLeftBottomTool == "build")
        #expect(viewModel.isLeftTopToolPresented(fileTree))
        #expect(viewModel.isLeftBottomToolPresented(build))
        viewModel.activateLeftBottomTool(build)
        #expect(!viewModel.showBottomPanel)
        #expect(!viewModel.isLeftBottomToolPresented(build))
        #expect(viewModel.isLeftTopToolPresented(fileTree))
        viewModel.activateLeftBottomTool(build)
        #expect(viewModel.showBottomPanel)
        #expect(viewModel.isLeftBottomToolPresented(build))

        viewModel.activateRightTool(inspector)
        #expect(viewModel.showRightPanel)
        #expect(viewModel.isRightToolPresented(inspector))
        viewModel.activateRightTool(inspector)
        #expect(!viewModel.showRightPanel)
        #expect(!viewModel.isRightToolPresented(inspector))
        viewModel.activateRightTool(settings)
        #expect(!viewModel.showRightPanel)
        #expect(viewModel.toolStrip.activeRightTool == "inspector")
        #expect(!viewModel.isRightToolPresented(settings))
        #expect(viewModel.requestedSettingsSection == .project)
        #expect(viewModel.settingsPresentationToken == 1)
    }

    @Test("settings commands request the platform settings presentation")
    @MainActor
    func settingsCommandsRequestPlatformPresentation() {
        let viewModel = EditorViewModel()

        #expect(viewModel.handleMenuCommand(.showSettings))
        #expect(viewModel.requestedSettingsSection == .general)
        #expect(viewModel.settingsPresentationToken == 1)
        #expect(!viewModel.showRightPanel)

        #expect(viewModel.handleMenuCommand(.showProjectSettings))
        #expect(viewModel.requestedSettingsSection == .project)
        #expect(viewModel.settingsPresentationToken == 2)
        #expect(!viewModel.showRightPanel)
    }

    @Test("settings presentation binding dismisses the requested section")
    @MainActor
    func settingsPresentationBindingDismissesRequestedSection() {
        let viewModel = EditorViewModel()

        viewModel.presentSettings(.agent)
        #expect(viewModel.settingsPresentationBinding.wrappedValue == .agent)

        viewModel.settingsPresentationBinding.wrappedValue = nil
        #expect(viewModel.requestedSettingsSection == nil)
    }

    @Test("settings window reserves a draggable title bar")
    @MainActor
    func settingsWindowReservesDraggableTitleBar() {
        let configuration = EditorSettingsWindowController.windowConfiguration

        #expect(configuration.titleBar.background == .transparent)
        #expect(configuration.titleBar.reservesSafeArea)
        #expect(configuration.titleBar.dragRegionHeight == EditorSettingsWindowController.titleBarDragRegionHeight)
    }

    @Test("modal settings close button invokes dismiss")
    @MainActor
    func modalSettingsCloseButtonInvokesDismiss() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let app = AppWorlds(main: World(name: "EditorSettingsDismissTests"))
            RenderWorldPlugin().setup(in: app)
        }
        let settingsViewModel = EditorSettingsWindowViewModel(editorViewModel: EditorViewModel(), selectedSection: .general)
        var didDismiss = false
        let container = UIContainerView(
            rootView: EditorSettingsWindowView(viewModel: settingsViewModel, showsCloseButton: true)
                .environment(\.dismiss, DismissAction { didDismiss = true })
        )
        container.frame = Rect(x: 0, y: 0, width: 1024, height: 700)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        _ = try container.uiTapNode(matching: .accessibilityIdentifier(EditorSettingsWindowView.closeAccessibilityIdentifier))

        #expect(didDismiss)
    }

    @Test("settings search filters navigation sections")
    @MainActor
    func settingsSearchFiltersNavigationSections() {
        let editorViewModel = EditorViewModel()
        let settingsViewModel = EditorSettingsWindowViewModel(editorViewModel: editorViewModel, selectedSection: .general)

        #expect(settingsViewModel.filteredSections == [.general, .project, .agent])
        settingsViewModel.searchText = "agent"
        #expect(settingsViewModel.filteredSections == [.agent])
        #expect(settingsViewModel.editorViewModel === editorViewModel)
    }

    @Test("settings headings remain on one line")
    @MainActor
    func settingsHeadingsRemainOnOneLine() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let app = AppWorlds(main: World(name: "EditorSettingsLayoutTests"))
            RenderWorldPlugin().setup(in: app)
        }
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorSettingsLayout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "SettingsLayout"), at: projectURL)
        let editorViewModel = EditorViewModel(
            project: EditorProjectReference(name: "SettingsLayout", path: projectURL.path)
        )
        let settingsViewModel = EditorSettingsWindowViewModel(editorViewModel: editorViewModel, selectedSection: .project)
        let container = UIContainerView(rootView: EditorSettingsWindowView(viewModel: settingsViewModel))
        container.frame = Rect(
            x: 0,
            y: 0,
            width: EditorSettingsWindowController.windowWidth,
            height: EditorSettingsWindowController.windowHeight
        )
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        let title = try container.uiNode(matching: .accessibilityIdentifier("AdaUI.NavigationBar.Title"))
        let buildSelection = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Settings.Group.BUILD FILE SELECTION"))

        #expect(title.absoluteFrame.height < 40)
        #expect(buildSelection.absoluteFrame.height < 24)
    }

    @Test("general settings apply code font and syntax appearance")
    @MainActor
    func generalSettingsApplyCodeAppearance() {
        let editorViewModel = EditorViewModel()
        let settingsViewModel = EditorSettingsWindowViewModel(editorViewModel: editorViewModel, selectedSection: .general)

        settingsViewModel.increaseCodeFontSize()
        settingsViewModel.selectCodeFontFamily(.system)
        settingsViewModel.selectCodeFontWeight(.regular)
        settingsViewModel.selectKeywordFontWeight(.semibold)
        settingsViewModel.selectCodePalette(.monokai)
        settingsViewModel.applyGeneralSettings()

        #expect(editorViewModel.workbench.codeFontSize == 13)
        #expect(editorViewModel.workbench.codeFontFamily == .system)
        #expect(editorViewModel.workbench.codeFontWeight == .regular)
        #expect(editorViewModel.workbench.keywordFontWeight == .semibold)
        #expect(editorViewModel.workbench.codeColorPalette == EditorCodeColorPalette.monokai)
        #expect(settingsViewModel.generalSettingsStatusMessage == "Applied to open editors")
    }

    @Test("workbench closes tabs and keeps a valid active document")
    @MainActor
    func workbenchClosesTabs() {
        let workbench = EditorWorkbenchViewModel()
        let initialDocumentCount = workbench.openDocuments.count
        let inactiveDocumentID = workbench.openDocuments[0].id
        let activeDocumentID = workbench.activeDocumentID

        workbench.closeDocument(id: inactiveDocumentID)
        #expect(workbench.openDocuments.count == initialDocumentCount - 1)
        #expect(workbench.activeDocumentID == activeDocumentID)
        #expect(workbench.activeEditorTab == "Main.ascn")

        workbench.closeDocument(id: activeDocumentID)
        #expect(workbench.openDocuments.isEmpty)
        #expect(workbench.activeDocumentID.isEmpty)
        #expect(workbench.activeEditorTab.isEmpty)
    }

    @Test("workbench navigates backward and forward through visited documents")
    @MainActor
    func workbenchDocumentNavigationHistory() {
        let firstDocument = AdaEngineStyleContent.defaultEditorDocuments[0]
        let secondDocument = AdaEngineStyleContent.defaultEditorDocuments[1]
        let thirdDocument = EditorWorkbenchDocument.text(
            EditorTextDocument(
                id: "text:Sources/Third.swift",
                title: "Third.swift",
                relativePath: "Sources/Third.swift",
                language: .swift,
                content: "let third = true\n"
            )
        )
        let workbench = EditorWorkbenchViewModel(
            openDocuments: [firstDocument, secondDocument, thirdDocument],
            activeDocumentID: firstDocument.id
        )

        workbench.selectDocument(id: secondDocument.id)
        workbench.selectDocument(id: thirdDocument.id)

        #expect(workbench.navigateBack())
        #expect(workbench.activeDocumentID == secondDocument.id)
        #expect(workbench.navigateBack())
        #expect(workbench.activeDocumentID == firstDocument.id)
        #expect(!workbench.navigateBack())

        #expect(workbench.navigateForward())
        #expect(workbench.activeDocumentID == secondDocument.id)
        #expect(workbench.navigateForward())
        #expect(workbench.activeDocumentID == thirdDocument.id)
        #expect(!workbench.navigateForward())
    }

    @Test("new document selection clears forward navigation history")
    @MainActor
    func workbenchDocumentNavigationBranches() {
        let firstDocument = AdaEngineStyleContent.defaultEditorDocuments[0]
        let secondDocument = AdaEngineStyleContent.defaultEditorDocuments[1]
        let thirdDocument = EditorWorkbenchDocument.text(
            EditorTextDocument(
                id: "text:Sources/Third.swift",
                title: "Third.swift",
                relativePath: "Sources/Third.swift",
                language: .swift,
                content: "let third = true\n"
            )
        )
        let workbench = EditorWorkbenchViewModel(
            openDocuments: [firstDocument, secondDocument, thirdDocument],
            activeDocumentID: firstDocument.id
        )

        workbench.selectDocument(id: secondDocument.id)
        workbench.selectDocument(id: thirdDocument.id)
        #expect(workbench.navigateBack())
        workbench.selectDocument(id: firstDocument.id)

        #expect(!workbench.navigateForward())
        #expect(workbench.activeDocumentID == firstDocument.id)
    }

    @Test("mouse side buttons map to editor navigation directions")
    @MainActor
    func mouseSideButtonNavigationDirections() {
        #expect(EditorNavigationMouseShortcutMonitor.direction(forButtonNumber: 3) == .back)
        #expect(EditorNavigationMouseShortcutMonitor.direction(forButtonNumber: 4) == .forward)
        #expect(EditorNavigationMouseShortcutMonitor.direction(forButtonNumber: 2) == nil)
    }

    @Test("workbench tab menu close commands keep the selected document")
    @MainActor
    func workbenchTabMenuCloseCommands() {
        let thirdDocument = EditorWorkbenchDocument.text(
            EditorTextDocument(
                id: "text:Sources/Third.swift",
                title: "Third.swift",
                relativePath: "Sources/Third.swift",
                language: .swift,
                content: "let third = true\n"
            )
        )
        let workbench = EditorWorkbenchViewModel(
            openDocuments: AdaEngineStyleContent.defaultEditorDocuments + [thirdDocument],
            activeDocumentID: thirdDocument.id
        )
        let keptDocumentID = AdaEngineStyleContent.defaultEditorDocuments[1].id

        workbench.closeDocumentsToLeft(of: keptDocumentID)
        #expect(workbench.openDocuments.map(\.id) == [keptDocumentID, thirdDocument.id])

        workbench.closeDocumentsToRight(of: keptDocumentID)
        #expect(workbench.openDocuments.map(\.id) == [keptDocumentID])
        #expect(workbench.activeDocumentID == keptDocumentID)
    }

    @Test("editor opens text files as code documents and scene files as editable scene documents")
    @MainActor
    func editorOpensTextAndSceneProjectFiles() throws {
        let rootURL = try makeAdaEngineStyleUITemporaryDirectory(named: "EditorProjectDocuments")
        defer { removeAdaEngineStyleUITemporaryDirectory(rootURL) }

        let sourcesURL = rootURL.appendingPathComponent("Sources/Game", isDirectory: true)
        let scenesURL = rootURL.appendingPathComponent("Assets/Scenes", isDirectory: true)
        let metadataURL = rootURL.appendingPathComponent(ProjectSystem.metadataDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scenesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.2\n".write(to: rootURL.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "{}\n".write(to: rootURL.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)
        try "{}\n".write(to: metadataURL.appendingPathComponent(ProjectSystem.metadataFileName), atomically: true, encoding: .utf8)
        try "import AdaEngine\n\nstruct GameScene {}\n".write(to: sourcesURL.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "format: ada.scene\nschemaVersion: 1\nscene:\n  id: main\n  name: Main\nentities: []\n"
            .write(
                to: scenesURL.appendingPathComponent("Main.ascn"),
                atomically: true,
                encoding: .utf8
            )

        let project = EditorProjectReference(name: "EditorProjectDocuments", path: rootURL.path)
        let viewModel = EditorViewModel(project: project)

        #expect(viewModel.projectSidebar.items.contains { $0.relativePath == "Package.swift" })
        #expect(viewModel.projectSidebar.items.contains { $0.relativePath == "Package.resolved" })
        #expect(!viewModel.projectSidebar.items.contains { $0.relativePath.hasPrefix(ProjectSystem.metadataDirectoryName) })

        let swiftItem = try #require(viewModel.projectSidebar.items.first { $0.relativePath == "Sources/Game/main.swift" })
        viewModel.openProjectItem(swiftItem)

        guard case let .text(textDocument) = viewModel.workbench.activeDocument else {
            Issue.record("Expected a text document")
            return
        }
        #expect(textDocument.title == "main.swift")
        #expect(textDocument.language == .swift)
        #expect(textDocument.content.contains("struct GameScene"))

        let sceneItem = try #require(viewModel.projectSidebar.items.first { $0.relativePath == "Assets/Scenes/Main.ascn" })
        viewModel.openProjectItem(sceneItem)

        guard case let .scene(sceneDocument) = viewModel.workbench.activeDocument else {
            Issue.record("Expected a scene document")
            return
        }
        #expect(sceneDocument.title == "Main.ascn")
        #expect(sceneDocument.content.contains("format: ada.scene"))
        #expect(sceneDocument.isDirty == false)
        #expect(sceneDocument.loadSummary.entityCount == 0)
        viewModel.workbench.updateSceneLine(documentID: sceneDocument.id, lineIndex: 1, value: "schemaVersion: 2")
        guard case let .scene(editedSceneDocument) = viewModel.workbench.activeDocument else {
            Issue.record("Expected an edited scene document")
            return
        }
        #expect(editedSceneDocument.content.contains("schemaVersion: 2"))
        #expect(editedSceneDocument.isDirty)
        viewModel.workbench.saveSceneDocument(id: editedSceneDocument.id)
        #expect(try String(contentsOf: scenesURL.appendingPathComponent("Main.ascn"), encoding: .utf8).contains("schemaVersion: 2"))
        #expect(viewModel.workbench.activeEditorTab == "Main.ascn")
        #expect(viewModel.toolbar.sceneName == "Main")

        viewModel.openProjectItemAsRaw(sceneItem)
        guard case let .text(rawDocument) = viewModel.workbench.activeDocument else {
            Issue.record("Expected a raw text document")
            return
        }
        #expect(rawDocument.id == "raw:Assets/Scenes/Main.ascn")
        #expect(rawDocument.language == .yaml)
        #expect(rawDocument.content.contains("schemaVersion: 2"))
    }

    @Test("editor saves text document on command save and tab switch")
    @MainActor
    func editorSavesTextDocumentOnCommandSaveAndTabSwitch() throws {
        let rootURL = try makeAdaEngineStyleUITemporaryDirectory(named: "EditorTextAutosave")
        defer { removeAdaEngineStyleUITemporaryDirectory(rootURL) }

        let sourcesURL = rootURL.appendingPathComponent("Sources/Game", isDirectory: true)
        let metadataURL = rootURL.appendingPathComponent(ProjectSystem.metadataDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.2\n".write(to: rootURL.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "{}\n".write(to: metadataURL.appendingPathComponent(ProjectSystem.metadataFileName), atomically: true, encoding: .utf8)

        let mainURL = sourcesURL.appendingPathComponent("main.swift")
        let otherURL = sourcesURL.appendingPathComponent("Other.swift")
        try "let value = 1\n".write(to: mainURL, atomically: true, encoding: .utf8)
        try "let other = 2\n".write(to: otherURL, atomically: true, encoding: .utf8)

        let project = EditorProjectReference(name: "EditorTextAutosave", path: rootURL.path)
        let viewModel = EditorViewModel(project: project)
        let mainItem = try #require(viewModel.projectSidebar.items.first { $0.relativePath == "Sources/Game/main.swift" })
        let otherItem = try #require(viewModel.projectSidebar.items.first { $0.relativePath == "Sources/Game/Other.swift" })

        viewModel.openProjectItem(mainItem)
        let mainDocumentID = try #require(viewModel.workbench.activeDocument?.id)
        viewModel.workbench.updateTextDocument(id: mainDocumentID) { document in
            document.content = "let value = 42\n"
            document.isDirty = true
        }
        viewModel.saveActiveDocument()

        #expect(try String(contentsOf: mainURL, encoding: .utf8) == "let value = 42\n")
        guard case let .text(savedMainDocument)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected the saved text document to remain active")
            return
        }
        #expect(!savedMainDocument.isDirty)
        #expect(savedMainDocument.statusMessage == "Saved")

        viewModel.workbench.updateTextDocument(id: mainDocumentID) { document in
            document.content = "let value = 99\n"
            document.isDirty = true
        }
        viewModel.openProjectItem(otherItem)

        #expect(try String(contentsOf: mainURL, encoding: .utf8) == "let value = 99\n")
        guard case let .text(otherDocument)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected tab switch to activate the other text document")
            return
        }
        #expect(otherDocument.absolutePath?.hasSuffix("Sources/Game/Other.swift") == true)
    }

    @Test("editor scene loader instantiates known entities and components")
    @MainActor
    func editorSceneLoaderInstantiatesKnownEntitiesAndComponents() {
        Transform.registerComponent()

        let world = World()
        let result = EditorSceneFileLoader.load(content: SceneDocumentFormat.defaultSceneYAML(projectName: "Main"), into: world)
        let entities = world.getEntities()

        #expect(result.entityCount == 1)
        #expect(result.warnings.isEmpty)
        #expect(entities.count == 1)
        #expect(entities.first?.name == "Root")
        #expect(entities.first?.components[Transform.self] != nil)
    }

    @Test("editor scene loader reports unknown components without failing")
    @MainActor
    func editorSceneLoaderReportsUnknownComponentsWithoutFailing() {
        let content = SceneDocumentFormat.defaultSceneYAML(projectName: "Main")
            .replacingOccurrences(of: "AdaTransform.Transform:", with: "Game.UnknownComponent:")

        let world = World()
        let result = EditorSceneFileLoader.load(content: content, into: world)

        #expect(result.entityCount == 1)
        #expect(result.warnings.contains("Unknown component: Game.UnknownComponent"))
        #expect(world.getEntities().count == 1)
    }

    @Test("project sidebar folders can collapse and expand")
    @MainActor
    func projectSidebarFoldersCollapseAndExpand() throws {
        let rootURL = try makeAdaEngineStyleUITemporaryDirectory(named: "EditorProjectSidebarCollapse")
        defer { removeAdaEngineStyleUITemporaryDirectory(rootURL) }

        let sourcesURL = rootURL.appendingPathComponent("Sources/Game", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
        try "import AdaEngine\n".write(to: sourcesURL.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

        let project = EditorProjectReference(name: "EditorProjectSidebarCollapse", path: rootURL.path)
        let viewModel = EditorViewModel(project: project)
        let sourcesItem = try #require(viewModel.projectSidebar.items.first { $0.relativePath == "Sources" })
        viewModel.projectSidebar.selectDisplayMode(.files)

        #expect(viewModel.projectSidebar.visibleItems.contains { $0.relativePath == "Sources/Game/main.swift" })
        viewModel.openProjectItem(sourcesItem)
        #expect(viewModel.projectSidebar.isCollapsed(sourcesItem))
        #expect(!viewModel.projectSidebar.visibleItems.contains { $0.relativePath == "Sources/Game/main.swift" })
        viewModel.openProjectItem(sourcesItem)
        #expect(!viewModel.projectSidebar.isCollapsed(sourcesItem))
        #expect(viewModel.projectSidebar.visibleItems.contains { $0.relativePath == "Sources/Game/main.swift" })
    }

    @Test("project sidebar defaults to target roots and can show all files")
    @MainActor
    func projectSidebarDisplayModeFiltersToTargets() throws {
        let rootURL = try makeAdaEngineStyleUITemporaryDirectory(named: "EditorProjectSidebarTargets")
        defer { removeAdaEngineStyleUITemporaryDirectory(rootURL) }

        let gameURL = rootURL.appendingPathComponent("Sources/Game", isDirectory: true)
        let toolsURL = rootURL.appendingPathComponent("Sources/Tools", isDirectory: true)
        let assetsURL = rootURL.appendingPathComponent("Assets/Scenes", isDirectory: true)
        try FileManager.default.createDirectory(at: gameURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: toolsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try "print(\"game\")\n".write(to: gameURL.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "print(\"tool\")\n".write(to: toolsURL.appendingPathComponent("tool.swift"), atomically: true, encoding: .utf8)
        try "scene: Main\n".write(to: assetsURL.appendingPathComponent("Main.ascn"), atomically: true, encoding: .utf8)
        try "# Project\n".write(to: rootURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "// package\n".write(to: rootURL.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let viewModel = EditorViewModel(project: EditorProjectReference(name: "EditorProjectSidebarTargets", path: rootURL.path))

        #expect(viewModel.projectSidebar.displayMode == .targets)
        #expect(
            viewModel.projectSidebar.visibleItems.map(\.relativePath) == [
                "Assets",
                "Assets/Scenes",
                "Assets/Scenes/Main.ascn",
                "Sources/Game",
                "Sources/Game/main.swift",
                "Sources/Tools",
                "Sources/Tools/tool.swift",
            ]
        )

        viewModel.projectSidebar.collapseAll()
        #expect(
            viewModel.projectSidebar.visibleItems.map(\.relativePath) == [
                "Assets",
                "Sources/Game",
                "Sources/Tools",
            ]
        )

        viewModel.projectSidebar.expandAll()
        #expect(viewModel.projectSidebar.visibleItems.contains { $0.relativePath == "Sources/Game/main.swift" })

        viewModel.projectSidebar.selectDisplayMode(.files)
        #expect(viewModel.projectSidebar.visibleItems.contains { $0.relativePath == "Sources" })
        #expect(viewModel.projectSidebar.visibleItems.contains { $0.relativePath == "README.md" })
        #expect(viewModel.projectSidebar.visibleItems.contains { $0.relativePath == "Package.swift" })
    }

    @Test("AdaScript-only project exposes its source root as a target")
    @MainActor
    func adaScriptProjectSidebarShowsTarget() throws {
        let rootURL = try makeAdaEngineStyleUITemporaryDirectory(named: "EditorProjectSidebarAdaScript")
        defer { removeAdaEngineStyleUITemporaryDirectory(rootURL) }

        let sourcesURL = rootURL.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
        try "@view(id: \"game.main\") class MainView {}\n"
            .write(
                to: sourcesURL.appendingPathComponent("Main.ada", isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
        _ = try ProjectSystem.createDefaultProject(at: rootURL, buildSystem: .adaScript)

        let viewModel = EditorViewModel(
            project: EditorProjectReference(name: "EditorProjectSidebarAdaScript", path: rootURL.path)
        )

        #expect(viewModel.projectSidebar.displayMode == .targets)
        #expect(
            viewModel.projectSidebar.visibleItems.map(\.relativePath) == [
                "Sources",
                "Sources/Main.ada",
            ]
        )
        #expect(viewModel.projectSidebar.visibleItems.first?.title == "EditorProjectSidebarAdaScript")

        viewModel.projectSidebar.collapseAll()
        #expect(viewModel.projectSidebar.visibleItems.map(\.relativePath) == ["Sources"])
    }

    @Test("project sidebar deletes real project files and closes their editors")
    @MainActor
    func projectSidebarDeletesProjectFiles() throws {
        let rootURL = try makeAdaEngineStyleUITemporaryDirectory(named: "EditorProjectSidebarDelete")
        defer { removeAdaEngineStyleUITemporaryDirectory(rootURL) }

        let sourceURL = rootURL.appendingPathComponent("Sources/Game", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        let fileURL = sourceURL.appendingPathComponent("Player.swift", isDirectory: false)
        try "struct Player {}\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let viewModel = EditorViewModel(project: EditorProjectReference(name: "EditorProjectSidebarDelete", path: rootURL.path))
        let item = try #require(viewModel.projectSidebar.items.first { $0.relativePath == "Sources/Game/Player.swift" })
        viewModel.openProjectItem(item)
        #expect(viewModel.workbench.openDocuments.contains { $0.relativePath == "Sources/Game/Player.swift" })

        viewModel.presentDeleteProjectItemAlert(item)
        #expect(viewModel.pendingDeleteProjectItem == item)
        #expect(viewModel.deleteProjectItem(item))

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(!viewModel.projectSidebar.items.contains { $0.relativePath == "Sources/Game/Player.swift" })
        #expect(!viewModel.workbench.openDocuments.contains { $0.relativePath == "Sources/Game/Player.swift" })
        #expect(viewModel.pendingDeleteProjectItem == nil)
    }

    @Test("toolbar search finds nested project files and supports a folder scope")
    @MainActor
    func toolbarSearchFindsProjectFiles() throws {
        let rootURL = try makeAdaEngineStyleUITemporaryDirectory(named: "EditorProjectSearch")
        defer { removeAdaEngineStyleUITemporaryDirectory(rootURL) }

        let gameSourcesURL = rootURL.appendingPathComponent("Sources/Game", isDirectory: true)
        let toolsSourcesURL = rootURL.appendingPathComponent("Sources/Tools", isDirectory: true)
        let metadataURL = rootURL.appendingPathComponent(ProjectSystem.metadataDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: gameSourcesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: toolsSourcesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
        try "print(\"game\")\n".write(to: gameSourcesURL.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "print(\"tool\")\n".write(to: toolsSourcesURL.appendingPathComponent("main-tool.swift"), atomically: true, encoding: .utf8)
        try "{}\n".write(to: metadataURL.appendingPathComponent(ProjectSystem.metadataFileName), atomically: true, encoding: .utf8)

        let viewModel = EditorViewModel(project: EditorProjectReference(name: "EditorProjectSearch", path: rootURL.path))
        viewModel.toolbar.searchText = "main"
        #expect(
            viewModel.toolbar.searchResults.map(\.relativePath) == [
                "Sources/Game/main.swift",
                "Sources/Tools/main-tool.swift",
            ]
        )
        #expect(!viewModel.toolbar.searchResults.contains { $0.relativePath.hasPrefix(".ada") })

        let gameFolder = try #require(viewModel.projectSidebar.items.first { $0.relativePath == "Sources/Game" })
        viewModel.findInProjectFolder(gameFolder)
        viewModel.toolbar.searchText = "main"
        #expect(viewModel.toolbar.searchResults.map(\.relativePath) == ["Sources/Game/main.swift"])

        let result = try #require(viewModel.toolbar.searchResults.first)
        viewModel.openSearchResult(result)
        #expect(viewModel.workbench.activeDocument?.relativePath == "Sources/Game/main.swift")
        #expect(viewModel.toolbar.searchText.isEmpty)
        #expect(viewModel.toolbar.searchScopeRelativePath == nil)
    }

    @Test("new file dialog creates each supported file type in the selected folder")
    @MainActor
    func newFileDialogCreatesSupportedFiles() throws {
        let rootURL = try makeAdaEngineStyleUITemporaryDirectory(named: "EditorNewFile")
        defer { removeAdaEngineStyleUITemporaryDirectory(rootURL) }

        let sourcesURL = rootURL.appendingPathComponent("Sources/Game", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.2\n"
            .write(
                to: rootURL.appendingPathComponent("Package.swift"),
                atomically: true,
                encoding: .utf8
            )

        let viewModel = EditorViewModel(
            project: EditorProjectReference(name: "EditorNewFile", path: rootURL.path)
        )
        let sourcesFolder = try #require(
            viewModel.projectSidebar.items.first { $0.relativePath == "Sources/Game" }
        )
        viewModel.projectSidebar.select(sourcesFolder)

        let cases: [(EditorNewFileKind, String, String)] = [
            (.scene, "Level", "Level.ascn"),
            (.script, "Movement", "Movement.ada"),
            (.swift, "Player", "Player.swift"),
            (.plainText, "Notes", "Notes.txt"),
        ]
        #expect(EditorNewFileKind.script.title == "System")
        #expect(EditorNewFileKind.script.detail == "ECS system in the update scheduler")

        for (kind, enteredName, expectedName) in cases {
            viewModel.presentNewFileDialog()
            #expect(viewModel.newFileDestinationRelativePath == "Sources/Game")
            viewModel.newFileKind = kind
            viewModel.newFileName = enteredName

            #expect(viewModel.createNewFile())
            let fileURL = sourcesURL.appendingPathComponent(expectedName)
            #expect(FileManager.default.fileExists(atPath: fileURL.path))
            #expect(viewModel.workbench.activeDocument?.relativePath == "Sources/Game/\(expectedName)")
            #expect(!viewModel.isNewFileDialogPresented)
        }

        let scene = try String(contentsOf: sourcesURL.appendingPathComponent("Level.ascn"), encoding: .utf8)
        #expect(scene.contains("format: ada.scene"))
        let adaSource = try String(contentsOf: sourcesURL.appendingPathComponent("Movement.ada"), encoding: .utf8)
        #expect(
            adaSource == """
                // Movement.ada

                @system(scheduler: "update")
                class MovementSystem {
                    func update(context: AdaSystemContext) {
                    }
                }
                """
        )
        let gravityPlugin = try AdaScriptPlugin(source: adaSource)
        #expect(gravityPlugin.name == "AdaScript")
        #expect(try String(contentsOf: sourcesURL.appendingPathComponent("Player.swift"), encoding: .utf8) == "import AdaEngine\n\n")
        #expect(try String(contentsOf: sourcesURL.appendingPathComponent("Notes.txt"), encoding: .utf8).isEmpty)
    }

    @Test("new file validation keeps the dialog open and never overwrites files")
    @MainActor
    func newFileValidationRejectsInvalidAndDuplicateNames() throws {
        let rootURL = try makeAdaEngineStyleUITemporaryDirectory(named: "EditorNewFileValidation")
        defer { removeAdaEngineStyleUITemporaryDirectory(rootURL) }
        try "original\n".write(to: rootURL.appendingPathComponent("Existing.swift"), atomically: true, encoding: .utf8)

        let viewModel = EditorViewModel(
            project: EditorProjectReference(name: "EditorNewFileValidation", path: rootURL.path)
        )
        viewModel.presentNewFileDialog()
        viewModel.newFileKind = .swift
        viewModel.newFileName = "Nested/File"
        #expect(!viewModel.createNewFile())
        #expect(viewModel.newFileErrorMessage?.contains("path separators") == true)
        #expect(viewModel.isNewFileDialogPresented)

        viewModel.newFileName = "Existing.swift"
        #expect(!viewModel.createNewFile())
        #expect(viewModel.newFileErrorMessage?.contains("already exists") == true)
        #expect(try String(contentsOf: rootURL.appendingPathComponent("Existing.swift"), encoding: .utf8) == "original\n")
        #expect(viewModel.isNewFileDialogPresented)
    }

    @Test("new file dialog cancel resets state and requests dismissal")
    @MainActor
    func newFileDialogCancelDismissesCover() throws {
        let rootURL = try makeAdaEngineStyleUITemporaryDirectory(named: "EditorNewFileCancel")
        defer { removeAdaEngineStyleUITemporaryDirectory(rootURL) }

        let viewModel = EditorViewModel(
            project: EditorProjectReference(name: "EditorNewFileCancel", path: rootURL.path)
        )
        viewModel.presentNewFileDialog()
        var didDismiss = false
        let dismiss = DismissAction { didDismiss = true }

        EditorNewFileDialogActions.cancel(viewModel: viewModel, dismiss: dismiss)

        #expect(!viewModel.isNewFileDialogPresented)
        #expect(didDismiss)
    }

    @Test("successful new file creation requests dismissal")
    @MainActor
    func newFileDialogCreateDismissesCover() throws {
        let rootURL = try makeAdaEngineStyleUITemporaryDirectory(named: "EditorNewFileCreateDismiss")
        defer { removeAdaEngineStyleUITemporaryDirectory(rootURL) }

        let viewModel = EditorViewModel(
            project: EditorProjectReference(name: "EditorNewFileCreateDismiss", path: rootURL.path)
        )
        viewModel.presentNewFileDialog()
        viewModel.newFileKind = .plainText
        viewModel.newFileName = "CreatedFromDialog"
        var didDismiss = false
        let dismiss = DismissAction { didDismiss = true }

        #expect(EditorNewFileDialogActions.create(viewModel: viewModel, dismiss: dismiss))

        #expect(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("CreatedFromDialog.txt").path))
        #expect(!viewModel.isNewFileDialogPresented)
        #expect(didDismiss)
    }

    @Test("syntax highlighter uses configurable code palette")
    func syntaxHighlighterUsesConfigurableCodePalette() {
        var palette = EditorCodeColorPalette.dark
        palette.keyword = .green
        palette.string = .blue
        palette.comment = .red

        let tokens = EditorSyntaxHighlighter.tokens(
            for: #"let title = "Ada" // comment"#,
            language: .swift,
            palette: palette
        )

        #expect(tokens.contains(EditorCodeToken(text: "let", color: .green)))
        #expect(tokens.contains(EditorCodeToken(text: "Ada", color: .blue)))
        #expect(tokens.contains(EditorCodeToken(text: "// comment", color: .red)))
    }

    @Test("syntax highlighter supports JSON and YAML")
    func syntaxHighlighterSupportsJSONAndYAML() {
        var palette = EditorCodeColorPalette.dark
        palette.keyword = .green
        palette.string = .blue
        palette.number = .red
        palette.comment = .yellow
        palette.type = .orange

        let jsonTokens = EditorSyntaxHighlighter.tokens(
            for: #"{"name":"Ada","enabled":true,"count":12}"#,
            language: .json,
            palette: palette
        )
        #expect(jsonTokens.contains(EditorCodeToken(text: #""Ada""#, color: .blue)))
        #expect(jsonTokens.contains(EditorCodeToken(text: "true", color: .green)))
        #expect(jsonTokens.contains(EditorCodeToken(text: "12", color: .red)))

        let yamlTokens = EditorSyntaxHighlighter.tokens(
            for: "name: Ada\ncount: 12 # generated",
            language: .yaml,
            palette: palette
        )
        #expect(yamlTokens.contains(EditorCodeToken(text: "name", color: .orange)))
        #expect(yamlTokens.contains(EditorCodeToken(text: "12", color: .red)))
        #expect(yamlTokens.contains(EditorCodeToken(text: "# generated", color: .yellow)))
    }

    @Test("editor window drag passthrough delegates to interactive content")
    @MainActor
    func editorWindowDragPassthroughDelegatesToInteractiveContent() {
        let passthroughView = EditorWindowDragPassthroughView()
        passthroughView.frame = Rect(x: 0, y: 0, width: 320, height: 80)
        passthroughView.bounds.size = passthroughView.frame.size

        let interactiveSubview = UIView(frame: Rect(x: 40, y: 0, width: 160, height: 52))
        passthroughView.addSubview(interactiveSubview)

        let eventOnInteractiveContent = MouseEvent(
            window: RID(),
            button: .left,
            mousePosition: Point(x: 80, y: 20),
            phase: .began,
            modifierKeys: [],
            time: 0
        )
        let eventOnEmptyToolbarArea = MouseEvent(
            window: RID(),
            button: .left,
            mousePosition: Point(x: 260, y: 20),
            phase: .began,
            modifierKeys: [],
            time: 0
        )

        #expect(!passthroughView.uiAllowsWindowDrag(at: eventOnInteractiveContent.mousePosition, with: eventOnInteractiveContent))
        #expect(passthroughView.uiAllowsWindowDrag(at: eventOnEmptyToolbarArea.mousePosition, with: eventOnEmptyToolbarArea))
    }

    @Test("editor window content resizes to full window bounds")
    @MainActor
    func editorWindowContentResizesToFullWindowBounds() throws {
        let previousManager = UIWindowManager.shared
        let testManager = EditorWindowTestWindowManager()
        UIWindowManager.setShared(testManager)
        defer {
            if let previousManager {
                UIWindowManager.setShared(previousManager)
            }
        }

        let window = EditorWindow(frame: Rect(x: 0, y: 0, width: 640, height: 480))
        let resizedFrame = Rect(x: 0, y: 0, width: 1180, height: 760)
        window.frame = resizedFrame

        let inspectableView = try #require(window.inspectableView)
        #expect(inspectableView.frame == Rect(origin: .zero, size: resizedFrame.size))
        #expect(inspectableView.bounds.size == resizedFrame.size)

        let editorContentView = try #require(inspectableView.subviews.first)
        #expect(editorContentView.frame == Rect(origin: .zero, size: resizedFrame.size))
        #expect(editorContentView.bounds.size == resizedFrame.size)
    }
}

@MainActor
private final class EditorWindowTestWindowManager: UIWindowManager {
    override func showWindow(_: UIWindow, isFocused _: Bool) {}
    override func closeWindow(_: UIWindow) {}
    override func setWindowMode(_: UIWindow, mode _: UIWindow.Mode) {}
    override func setMinimumSize(_: Size, for _: UIWindow) {}
    override func resizeWindow(_: UIWindow, size _: Size) {}
    override func getScreen(for _: UIWindow) -> Screen? { nil }
}

private func makeAdaEngineStyleUITemporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func removeAdaEngineStyleUITemporaryDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

private func createPlayableProject(at rootURL: URL, sceneName: String) throws {
    let scenesURL = rootURL.appendingPathComponent("Assets/Scenes", isDirectory: true)
    try FileManager.default.createDirectory(at: scenesURL, withIntermediateDirectories: true)
    try "// swift-tools-version: 6.2\n".write(to: rootURL.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try SceneDocumentFormat.defaultSceneYAML(projectName: sceneName)
        .write(
            to: rootURL.appendingPathComponent(SceneDocumentFormat.defaultScenePath, isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    _ = try ProjectSystem.createDefaultProject(at: rootURL)
}
