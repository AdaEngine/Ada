@_spi(AdaEngine) import AdaEngine
import AdaSpine
import Foundation

struct EditorSceneViewportView: View {
    let document: EditorSceneDocument
    let resourceRootURL: URL?
    var uiCatalog: UICatalog = .standard
    let inspectorViewModel: EditorInspectorSidebarViewModel
    let playModeState: EditorPlayModeState
    let playRuntime: EditorScenePlayRuntime?
    let onEntitySelected: (() -> Void)?
    let onPlay: (() -> Void)?
    let onStop: (() -> Void)?
    let onDocumentChanged: (EditorSceneDocument) -> Void
    var initialDisplayMode: EditorSceneViewportDisplayMode = .twoD
    var isAssetPreview = false
    var onEditWorldReady: ((World) -> Void)?

    @State private var performanceSession = EditorGamePerformanceSession()
    @State var viewportPresentation = EditorViewportPresentation()
    @State var runtimeWarnings: [String] = []
    @State private var showsBones = false
    @State private var displayMode: EditorSceneViewportDisplayMode = .twoD
    @State private var activeTool: EditorSceneViewportTool = .translate
    @State var viewportModel = EditorSceneViewportModel()
    @Environment(\.theme) var theme
    @Environment(\.viewProxy) var viewProxy

    var body: some View {
        // A declaration is required inside AdaUI's result builder.
        // swiftlint:disable:next redundant_discardable_let
        let _ = isPlayingThisDocument ? preparePlayModeViewport() : configureViewportModel()
        ZStack {
            theme.editorColors.surfaceElevated

            if let errorMessage = document.errorMessage {
                viewportMessage(title: "Unable to open scene", message: errorMessage)
            } else if isPlayingThisDocument {
                playViewport
                    .onDisappear { performanceSession.stop() }
            } else {
                editViewport
            }
        }
        .accessibilityIdentifier("AdaEditor.SceneViewport.\(document.title)")
        .onAppear {
            selectViewportMode(hasImportedModels ? .threeD : initialDisplayMode)
            if isAssetPreview { selectTool(.select) }
        }
        .onChange(of: hasImportedModels) { _, hasModels in
            if hasModels { selectViewportMode(.threeD) }
        }
        .onDisappear {
            viewportModel.disconnect()
            inspectorViewModel.clearSceneViewportActions(owner: viewportModel)
        }
    }

    private var isPlayingThisDocument: Bool {
        if case let .playing(sceneDocumentID, _) = playModeState {
            return sceneDocumentID == document.id
        }

        return false
    }

    private var hasImportedModels: Bool {
        document.sceneModel?.entities.contains { $0.components[EditorBuiltInComponentType.model3DSource] != nil } == true
    }

    private var editViewport: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { geometry in
                ZStack(anchor: .bottomLeading) {
                    SceneView(
                        updatesWhenWindowInactive: false,
                        make: { app in
                            if isAssetPreview {
                                viewportModel.threeDPosition = Vector3(0, 0, -5)
                                viewportModel.threeDPitch = 0
                                viewportModel.perspectiveBlend = 1
                            }
                            guard configureSceneViewApp(&app) else { return }
                            let result = EditorSceneFileLoader.load(
                                content: document.content,
                                into: app.main,
                                loadsScriptableObjects: false,
                                sourceURL: document.absolutePath.map { URL(fileURLWithPath: $0) },
                                resourceRootURL: resourceRootURL
                            )
                            if runtimeWarnings != result.warnings {
                                runtimeWarnings = result.warnings
                            }
                            viewportModel.attachSceneWorld(app.main, loadResult: result)
                            redrawViewport()
                            onEditWorldReady?(app.main)
                        },
                        updateContent: { world, deltaTime in
                            world.getResource(EditorSkeleton3DOverlay.self)?.isEnabled = showsBones && displayMode == .threeD
                            var didChangeViewport = false
                            if let input = world.getResource(Input.self) {
                                for event in input.getInputEvents() {
                                    let handled = viewportModel.handleInput(event)
                                    didChangeViewport = didChangeViewport || handled
                                }
                            }
                            if viewportModel.update(deltaTime: deltaTime) {
                                didChangeViewport = true
                            }
                            if didChangeViewport {
                                redrawViewport()
                            }
                        }
                    )
                    .onPrepareFramePresentation {
                        viewportPresentation.prepareFrame(viewportModel: viewportModel, theme: viewportPresentation.annotationTheme)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)

                    viewportSceneOverlay
                        .frame(width: geometry.size.width, height: geometry.size.height)

                    sceneControls(size: geometry.size)
                    statusBar
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .mask(RectangleShape())
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
    }

    private var playViewport: some View {
        VStack(spacing: 0) {
            playToolbar
            GeometryReader { geometry in
                ZStack(anchor: .bottomLeading) {
                    AdaptiveSceneView(
                        layout: nil,
                        frameCaptureLabel: EditorGameFrameCapture.gameLabel,
                        useSceneCameras: true,
                        make: configurePlayWorld,
                        updateContent: { world, _ in
                            world.getResource(EditorSkeleton3DOverlay.self)?.isEnabled = showsBones && displayMode == .threeD
                        }
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    sceneControls(size: geometry.size)
                    playStatusBar
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .mask(RectangleShape())
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
    }

    func configurePlayWorld(_ app: inout AppWorlds) {
        guard configureSceneViewApp(&app) else { return }
        performanceSession.attach(app, title: document.title)
        var runtimeInstalled = true
        do {
            try playRuntime?.install(in: &app)
            if let resourceRootURL {
                let projectRoot = Self.uiProjectRoot(from: resourceRootURL)
                if FileManager.default.fileExists(atPath: ProjectSystem.metadataURL(forProjectAt: projectRoot).path) {
                    let project = try ProjectSystem.loadProject(at: projectRoot)
                    if var input = app.main.getResource(Input.self) {
                        try input.setInputActions(project.inputActions)
                        app.main.insertResource(input)
                    }
                }
            }
        } catch {
            runtimeWarnings = [error.localizedDescription]
            runtimeInstalled = false
        }
        guard let model = EditorSceneFileLoader.model(from: document.content) else {
            runtimeWarnings = ["Unable to play scene: invalid scene document."]
            return
        }
        let sourceURL = document.absolutePath.map { URL(fileURLWithPath: $0) }
        let assets = resourceRootURL ?? sourceURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let reportsLoad = runtimeInstalled
        app.addPlugin(EditorAdaScriptRuntimeEntryPlugin(sceneModel: model, assetsDirectory: assets, sourceURL: sourceURL,
            recordsAchievement: false, onInitialSceneLoaded: { result in
                if reportsLoad { runtimeWarnings = result.warnings }
                if reportsLoad, result.warnings.isEmpty, sourceURL != nil {
                    EditorAchievementBootstrap.center?.record(EditorAchievementRules.playedScene(model, adaScript: playRuntime != nil))
                }
            }))
    }

    @MainActor
    static func uiProjectRoot(from resourceRoot: URL) -> URL {
        var candidate = resourceRoot
        // Foundation maps the parent of "/" to "/../", so comparing with the parent never ends the walk
        // for a project that has no marker file in any ancestor (a temporary folder, for example).
        while candidate.standardizedFileURL.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".ada/project.json").path)
                || FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent.pathComponents.count < candidate.pathComponents.count else { break }
            candidate = parent
        }
        return resourceRoot
    }

    @MainActor
    static func assetDirectories(for resourceRoot: URL) throws -> ProjectDirectories {
        let assets = resourceRoot.standardizedFileURL
        let source = assets.deletingLastPathComponent()
        let projectRoot = uiProjectRoot(from: assets)
        if FileManager.default.fileExists(atPath: ProjectSystem.metadataURL(forProjectAt: projectRoot).path) {
            let project = try ProjectSystem.loadProject(at: projectRoot)
            if let identifier = try EditorProjectStorageIdentity.resolve(project) {
                return try ProjectDirectories(source: projectRoot, assetsDirectory: assets, storageIdentifier: identifier)
            }
        }
        return ProjectDirectories(source: source, assetsDirectory: assets)
    }

    private func configureSceneViewApp(_ app: inout AppWorlds) -> Bool {
        app.runtimeLogSource = isPlayingThisDocument ? "Game" : "Editor"
        if let resourceRootURL {
            let runtime = UIComponentRuntime(resourceRoot: resourceRootURL, catalog: uiCatalog)
            runtime.enableAdaScript(sourceRoot: Self.uiProjectRoot(from: resourceRootURL))
            app.main.insertResource(UIComponentRuntimeResource(runtime))
        }

        EditorComponentRegistry.registerBuiltIns()
        app.addPlugin(TransformPlugin())
        app.addPlugin(InputPlugin(actions: []))
        app.addPlugin(RenderWorldPlugin())
        app.addPlugin(EventsPlugin())
        app.addPlugin(CameraPlugin())
        if let resourceRootURL {
            do {
                app.addPlugin(AssetsPlugin(directories: try Self.assetDirectories(for: resourceRootURL)))
            } catch {
                runtimeWarnings = [error.localizedDescription]
                RuntimeLogStore.shared.append(level: "error", label: "AdaScript", message: error.localizedDescription)
                return false
            }
        } else {
            app.addPlugin(AssetsPlugin(filePath: #filePath))
        }
        app.addPlugin(VisibilityPlugin())
        app.addPlugin(SpritePlugin())
        app.addPlugin(Mesh2DPlugin())
        app.addPlugin(Model3DPlugin())
        app.addPlugin(EditorSkeleton3DPlugin())
        app.addPlugin(SpinePlugin())
        app.addPlugin(TextPlugin())
        app.addPlugin(ScenePlugin())
        // The editing camera is the editor's own; scene cameras are only driven while the scene plays.
        if isPlayingThisDocument { app.addPlugin(Camera2DControllerPlugin()) }
        Self.configureSimulation(in: app, isPlaying: isPlayingThisDocument)
        app.addPlugin(TileMapPlugin())
        app.addPlugin(Core2DPlugin())
        app.addPlugin(Core3DPlugin(includes2D: true))
        app.addPlugin(Light2DPlugin())
        app.addPlugin(UpscalePlugin())
        return true
    }

    @MainActor
    static func configureSimulation(in app: AppWorlds, isPlaying: Bool) {
        // Edit worlds render authored transforms without creating simulation bodies.
        guard isPlaying else {
            return
        }
        app.addPlugin(ScriptableObjectPlugin())
        app.addPlugin(Physics2DPlugin())
        app.addPlugin(Physics3DPlugin())
    }

    private var viewportSceneOverlay: some View {
        ZStack(anchor: .topLeading) {
            viewportGridLayer
            EditorSceneUIPreviewSurface(viewportModel: viewportModel)
            viewportGizmoLayer
            viewportCoordinateRulerLayer
            if displayMode == .threeD {
                EditorSceneViewportOrientationCompass(viewportModel: viewportModel, presentation: viewportPresentation)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)
            }
        }
        .allowsHitTesting(false)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(document.title)
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.text)
            #if !os(iOS)
            Text(document.relativePath)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
            #endif
            Spacer()
            if displayMode == .threeD {
                skeletonVisibilityButton
            }
            Text(isPlayingThisDocument ? L10n.text("PLAY MODE") : isAssetPreview ? L10n.text("MODEL PREVIEW") : L10n.text("SCENE"))
                .font(.system(size: 10))
                .foregroundColor(isPlayingThisDocument ? theme.editorColors.purple : theme.editorColors.muted)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(theme.editorColors.surface)
    }

    private var skeletonVisibilityButton: some View {
        Button(action: { showsBones.toggle() }) {
            Text(showsBones ? "Hide bones" : "Show bones").font(.system(size: 11))
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.SceneViewport.Bones")
    }

    private var playToolbar: some View {
        HStack(spacing: 8) {
            Text(document.title)
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.text)
            Spacer()
            if displayMode == .threeD { skeletonVisibilityButton }
            Text(L10n.text("PLAY MODE"))
                .font(.system(size: 10))
                .foregroundColor(theme.editorColors.purple)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(theme.editorColors.surface)
    }

    private func sceneControls(size: Size) -> some View {
        EditorSceneViewportControls(
            activeTool: activeTool,
            displayMode: displayMode,
            isPlaying: isPlayingThisDocument,
            size: size,
            onPlay: { onPlay?() },
            onSelectDisplayMode: selectViewportMode,
            onSelectTool: selectTool,
            onStop: { onStop?() },
            showsEditingTools: !isAssetPreview,
            showsPlayback: !isAssetPreview
        )
    }

    private var viewportGridLayer: some View {
        GeometryReader { proxy in
            // A declaration is required inside AdaUI's result builder.
            // swiftlint:disable:next redundant_discardable_let
            let _ = viewportModel.setViewportSize(proxy.size)
            EditorViewportDrawingLayer(viewportModel: viewportModel, presentation: viewportPresentation, kind: .grid)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private var viewportGizmoLayer: some View {
        GeometryReader { proxy in
            EditorViewportDrawingLayer(viewportModel: viewportModel, presentation: viewportPresentation, kind: .gizmos)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            EditorViewportStatusLabel(
                presentation: viewportPresentation,
                viewportModel: viewportModel,
                warning: (document.loadSummary.warnings + runtimeWarnings).first,
                entityCount: document.loadSummary.entityCount
            )
                .font(.system(size: 11))
                .foregroundColor(statusColor)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface.opacity(0.88)))
            Spacer()
        }
        .padding(.leading, 52)
        .padding(.trailing, 12)
        .padding(.bottom, 12)
    }

    private var playStatusBar: some View {
        HStack(spacing: 8) {
            Text(playStatusText)
                .font(.system(size: 11))
                .foregroundColor(playStatusColor)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface.opacity(0.88)))
            Spacer()
        }
        .padding(12)
    }

    private var playStatusText: String {
        let warnings = document.loadSummary.warnings + runtimeWarnings
        if let firstWarning = warnings.first {
            return "Play warning: \(firstWarning)"
        }

        return "Playing \(document.loadSummary.entityCount) entities"
    }

    private var statusColor: Color {
        (document.loadSummary.warnings + runtimeWarnings).isEmpty ? theme.editorColors.muted : theme.editorColors.purple
    }

    private var playStatusColor: Color {
        (document.loadSummary.warnings + runtimeWarnings).isEmpty ? theme.editorColors.muted : theme.editorColors.purple
    }

    private func selectViewportMode(_ mode: EditorSceneViewportDisplayMode) {
        displayMode = mode
        viewportModel.setDisplayMode(mode)
        redrawViewport()
    }

    @MainActor
    @discardableResult
    static func synchronizePlayCamera(in world: World) -> Bool {
        guard let displayCameraEntity = world.getEntities().first(where: {
            $0.name == "SceneView_Camera" && $0.components[Camera.self] != nil && $0.components[Transform.self] != nil
        }) else {
            return false
        }
        let authoredCameraEntity = world.getEntities()
            .filter {
                $0.id != displayCameraEntity.id
                    && $0.name != "SceneView_Camera"
                    && $0.components[Camera.self]?.isActive == true
                    && $0.components[Transform.self] != nil
            }
            .max(by: { ($0.components[Camera.self]?.renderOrder ?? 0) < ($1.components[Camera.self]?.renderOrder ?? 0) })
        guard
            let authoredCameraEntity,
            let authoredCamera = authoredCameraEntity.components[Camera.self],
            let authoredTransform = authoredCameraEntity.components[Transform.self],
            var displayCamera = displayCameraEntity.components[Camera.self]
        else {
            return false
        }

        displayCamera.projection = authoredCamera.projection
        let size = displayCamera.logicalViewport.rect.size
        if size.width > 0, size.height > 0 {
            // Authored 2D cameras may not have a window viewport of their own.
            // Fit every projection to the display target before Play renders it.
            displayCamera.projection.updateView(width: size.width, height: size.height)
        }
        displayCamera.isActive = true
        displayCamera.backgroundColor = authoredCamera.backgroundColor
        displayCamera.clearFlags = authoredCamera.clearFlags
        displayCamera.renderOrder = authoredCamera.renderOrder
        displayCameraEntity.components += displayCamera
        displayCameraEntity.components += authoredTransform

        let defaultGraphLabel: RenderGraph.Label =
            switch authoredCamera.projection {
            case .perspective:
                .main3D
            case .orthographic,
                .custom:
                .main2D
            }
        let renderGraph = authoredCameraEntity.components[CameraRenderGraph.self]
            ?? CameraRenderGraph(subgraphLabel: defaultGraphLabel, inputSlot: "view")
        displayCameraEntity.components += renderGraph
        if let environment = authoredCameraEntity.components[Environment3D.self] {
            displayCameraEntity.components += environment
        } else {
            world.remove(Environment3D.self, from: displayCameraEntity.id)
        }
        return true
    }

    private func selectTool(_ tool: EditorSceneViewportTool) {
        activeTool = tool
        viewportModel.setActiveTool(tool)
        redrawViewport()
    }

    private func viewportMessage(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr(title))
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
}
