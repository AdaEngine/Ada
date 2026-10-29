@_spi(AdaEngine) import AdaEngine
import AdaMultiplayer
import Foundation

enum EditorAdaScriptRuntimeError: Error, LocalizedError {
    case windowManagerUnavailable
    case runtimeNotReady

    var errorDescription: String? {
        switch self {
        case .windowManagerUnavailable:
            "AdaScript runtime cannot create a window because the window manager is unavailable."
        case .runtimeNotReady:
            "AdaScript runtime did not finish starting before the edit was applied."
        }
    }
}

@MainActor
struct EditorAdaScriptProjectRuntimeView: View {
    let performanceSession = EditorGamePerformanceSession()
    private let artifact: EditorAdaScriptProjectBuildArtifact
    private let controls: EditorGameWindowControls?
    private let previewCapture: EditorProjectPreviewCapture?
    private let entryView: AdaScriptView?
    private let scriptPlugin: AdaScriptPlugin?
    private let objectCatalog: AdaScriptObjectCatalog
    private let directories: ProjectDirectories
    @State private var overlaySession = EditorSceneUIOverlaySession()

    var diagnostics: [String] { (scriptPlugin?.diagnostics ?? []) + objectCatalog.diagnostics }

    init(
        artifact: EditorAdaScriptProjectBuildArtifact,
        controls: EditorGameWindowControls? = nil,
        previewCapture: EditorProjectPreviewCapture? = nil
    ) throws {
        self.artifact = artifact
        self.controls = controls
        self.previewCapture = previewCapture
        directories = try artifact.assetDirectories()
        EditorComponentRegistry.registerBuiltIns()
        // Scriptable UI resolves resource types before the world's plugins start.
        if artifact.plugins.contains(.multiplayer) {
            AdaScriptMultiplayerState.registerRuntimeType()
        }
        self.entryView = try artifact.entry.view.map { identifier in
            try AdaScriptView(
                sources: artifact.sources,
                identifier: identifier
            )
        }
        self.objectCatalog = try artifact.scenePlayRuntime.makeScriptableCatalog()
        self.scriptPlugin = try artifact.scenePlayRuntime.makeScriptPlugin()
    }

    var body: some View {
        VStack(spacing: 0) {
            if let controls {
                EditorGameWindowToolbar(controls: controls)
            }
            ZStack {
                SceneView(
                    isInteractive: controls?.inputEnabled ?? true,
                    useSceneCameras: usesSceneCameras,
                    make: { app in
                        configureRuntime(&app)
                    },
                    updateContent: { world, _ in
                        overlaySession.prepare(world)
                        controls?.refresh()
                    },
                    onFrameRendered: { texture in previewCapture?.capture(texture) }
                )
                .frameCaptureLabel(EditorGameFrameCapture.gameLabel)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)

                ForEach(overlaySession.views) { overlay in
                    EditorSceneUIOverlaySurface(content: overlay.view)
                        .allowsHitTesting(controls?.inputEnabled ?? true)
                }

                if let entryView {
                    entryView
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .allowsHitTesting(controls?.inputEnabled ?? true)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .background(.black)
        .onDisappear {
            performanceSession.stop()
            controls?.finish()
        }
    }

    var usesSceneCameras: Bool { artifact.plugins.contains(.core3D) || hasSceneCamera }

    private var hasSceneCamera: Bool {
        artifact.sceneModel?.entities.contains { entity in
            entity.components[EditorBuiltInComponentType.camera] != nil
        } == true
    }

    /// Installs the game's plugins and scene. Shared by the Play window and offscreen automation runs.
    func configureRuntime(_ app: inout AppWorlds, includesEntryScene: Bool = true) {
        performanceSession.attach(app, title: artifact.report.entryDescription)
        app.addPlugin(TransformPlugin())
        app.addPlugin(InputPlugin(actions: artifact.scenePlayRuntime.inputActions))
        app.addPlugin(RenderWorldPlugin())
        app.addPlugin(EventsPlugin())
        app.addPlugin(CameraPlugin())
        app.addPlugin(AssetsPlugin(directories: directories))
        app.addPlugin(VisibilityPlugin())
        app.addPlugin(TextPlugin())
        app.addPlugin(ScenePlugin(includesModel3D: artifact.plugins.contains(.model3D)))
        app.addPlugin(Camera2DControllerPlugin())
        app.addPlugin(EditorProjectScriptObjectsPlugin(catalog: objectCatalog))
        installFeaturePlugins(in: &app)
        if let scriptPlugin {
            app.addPlugin(scriptPlugin)
        }
        if includesEntryScene, let sceneModel = artifact.sceneModel {
            app.addPlugin(EditorAdaScriptRuntimeEntryPlugin(sceneModel: sceneModel, assetsDirectory: artifact.assetsDirectory))
        }
        controls?.attach(world: app.main)
        controls?.attach(
            app: app,
            scriptPlugin: scriptPlugin,
            sources: artifact.sources,
            scriptableSchemas: artifact.scenePlayRuntime.schemas,
            scriptableCatalog: objectCatalog
        )
    }

    private func installFeaturePlugins(in app: inout AppWorlds) {
        for pluginID in artifact.plugins.pluginIDs {
            if installRenderingPlugin(pluginID, in: &app) {
                continue
            }
            if installSimulationPlugin(pluginID, in: &app) {
                continue
            }
            installServicePlugin(pluginID, in: &app)
        }
    }

    private func installRenderingPlugin(
        _ pluginID: AdaProjectRuntimePluginID,
        in app: inout AppWorlds
    ) -> Bool {
        switch pluginID {
        case .core2D:
            app.addPlugin(Core2DPlugin())
        case .core3D:
            app.addPlugin(Core3DPlugin())
        case .light2D:
            app.addPlugin(Light2DPlugin())
        case .mesh2D:
            app.addPlugin(Mesh2DPlugin())
        case .model3D:
            break
        case .sprite:
            app.addPlugin(SpritePlugin())
        case .upscale:
            app.addPlugin(UpscalePlugin())
        default:
            return false
        }
        return true
    }

    private func installSimulationPlugin(
        _ pluginID: AdaProjectRuntimePluginID,
        in app: inout AppWorlds
    ) -> Bool {
        switch pluginID {
        case .navigation3D:
            app.addPlugin(Navigation3DPlugin())
        case .physics2D:
            let gravity = artifact.plugins.physics2DGravity
            app.addPlugin(Physics2DPlugin(gravity: [Float(gravity[0]), Float(gravity[1])]))
        case .physics3D:
            app.addPlugin(artifact.plugins.physics3DPlugin())
        default:
            return false
        }
        return true
    }

    private func installServicePlugin(
        _ pluginID: AdaProjectRuntimePluginID,
        in app: inout AppWorlds
    ) {
        switch pluginID {
        case .audio:
            app.addPlugin(artifact.plugins.audioPlugin())
        case .multiplayer:
            app.addPlugin(EditorAdaScriptMultiplayerPlugin(settings: artifact.plugins.multiplayer))
        case .tilemap:
            app.addPlugin(TileMapPlugin())
        default:
            assertionFailure("Unsupported runtime plugin: \(pluginID.rawValue)")
        }
    }
}

struct EditorAdaScriptRuntimeEntryPlugin: Plugin {
    let sceneModel: EditorSceneModel
    let assetsDirectory: URL
    var sourceURL: URL? = nil
    var recordsAchievement = true
    var onInitialSceneLoaded: (@MainActor @Sendable (EditorSceneRuntimeLoadResult) -> Void)? = nil

    func setup(in app: borrowing AppWorlds) {
        guard let navigator = app.main.getResource(SceneNavigator.self) else {
            assertionFailure("ScenePlugin must install SceneNavigator before the runtime entry")
            return
        }
        navigator.setSceneLoader { path, reportProgress in
            let url = try Self.sceneURL(for: path, in: assetsDirectory)
            let prepared = try await EditorRuntimeScenePreparation.prepare(at: url, assetsDirectory: assetsDirectory, reportProgress: reportProgress)
            // Give the outgoing UI a frame to display the installation stage.
            try await Task.sleep(for: .milliseconds(32))
            return try await MainActor.run {
                try withExtendedLifetime(prepared) {
                    let scene = Scene(name: prepared.model.scene.name)
                    let result = EditorSceneFileLoader.load(model: prepared.model, into: scene.world, sourceURL: url, resourceRootURL: assetsDirectory)
                    guard result.warnings.isEmpty else {
                        throw EditorRuntimeSceneNavigationError.invalidScene(result.warnings.joined(separator: "\n"))
                    }
                    return scene
                }
            }
        }
        let scene = Scene(name: sceneModel.scene.name)
        let result = EditorSceneFileLoader.load(model: sceneModel, into: scene.world, sourceURL: sourceURL, resourceRootURL: assetsDirectory)
        navigator.installInitialScene(scene, make: {
            let scene = Scene(name: sceneModel.scene.name)
            _ = EditorSceneFileLoader.load(model: sceneModel, into: scene.world, sourceURL: sourceURL, resourceRootURL: assetsDirectory)
            return scene
        })
        onInitialSceneLoaded?(result)
        if recordsAchievement, result.warnings.isEmpty {
            EditorAchievementBootstrap.center?.record(EditorAchievementRules.playedScene(sceneModel, adaScript: true))
        }
    }

    private static func sceneURL(for path: String, in root: URL) throws -> URL {
        guard path.hasPrefix("@res://"), path.hasSuffix(".ascn") else {
            throw EditorRuntimeSceneNavigationError.invalidPath(path)
        }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(String(path.dropFirst("@res://".count)))
            .resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else {
            throw EditorRuntimeSceneNavigationError.invalidPath(path)
        }
        return url
    }
}

private enum EditorRuntimeSceneNavigationError: Error, LocalizedError {
    case invalidPath(String)
    case invalidScene(String)

    var errorDescription: String? {
        switch self {
        case let .invalidPath(path): "Invalid project scene path: \(path)"
        case let .invalidScene(detail): "Cannot load scene: \(detail)"
        }
    }
}
