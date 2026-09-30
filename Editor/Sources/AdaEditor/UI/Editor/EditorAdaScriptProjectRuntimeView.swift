@_spi(AdaEngine) import AdaEngine
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

    var diagnostics: [String] { scriptPlugin?.diagnostics ?? [] }

    init(
        artifact: EditorAdaScriptProjectBuildArtifact,
        controls: EditorGameWindowControls? = nil,
        previewCapture: EditorProjectPreviewCapture? = nil
    ) throws {
        self.artifact = artifact
        self.controls = controls
        self.previewCapture = previewCapture
        EditorComponentRegistry.registerBuiltIns()
        self.entryView = try artifact.entry.view.map { identifier in
            try AdaScriptView(
                sources: artifact.sources,
                identifier: identifier
            )
        }
        try artifact.scenePlayRuntime.registerScriptableObjects()
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
                    make: { app in
                        configureRuntime(&app)
                    },
                    updateContent: { _, _ in controls?.refresh() },
                    onFrameRendered: { texture in previewCapture?.capture(texture) }
                )
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)

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

    private func configureRuntime(_ app: inout AppWorlds) {
        performanceSession.attach(app, title: artifact.report.entryDescription)
        app.addPlugin(TransformPlugin())
        app.addPlugin(InputPlugin(actions: artifact.scenePlayRuntime.inputActions))
        app.addPlugin(RenderWorldPlugin())
        app.addPlugin(EventsPlugin())
        app.addPlugin(CameraPlugin())
        app.addPlugin(AssetsPlugin(assetDirectory: artifact.assetsDirectory))
        app.addPlugin(VisibilityPlugin())
        app.addPlugin(TextPlugin())
        app.addPlugin(ScenePlugin(includesModel3D: artifact.plugins.contains(.model3D)))
        app.addPlugin(ScriptableObjectPlugin())
        installFeaturePlugins(in: &app)
        if let scriptPlugin {
            app.addPlugin(scriptPlugin)
        }
        if let sceneModel = artifact.sceneModel {
            app.addPlugin(EditorAdaScriptRuntimeEntryPlugin(sceneModel: sceneModel, assetsDirectory: artifact.assetsDirectory))
        }
        controls?.attach(world: app.main)
        controls?.attach(
            app: app,
            scriptPlugin: scriptPlugin,
            sources: artifact.sources,
            scriptableSchemas: artifact.scenePlayRuntime.schemas
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
        case .physics2D:
            let gravity = artifact.plugins.physics2DGravity
            app.addPlugin(Physics2DPlugin(gravity: [Float(gravity[0]), Float(gravity[1])]))
        case .physics3D:
            app.addPlugin(Physics3DPlugin())
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
            app.addPlugin(AudioPlugin())
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

    func setup(in app: borrowing AppWorlds) {
        guard let navigator = app.main.getResource(SceneNavigator.self) else {
            assertionFailure("ScenePlugin must install SceneNavigator before the runtime entry")
            return
        }
        navigator.setSceneLoader { path in
            let url = try Self.sceneURL(for: path, in: assetsDirectory)
            let content = try String(contentsOf: url, encoding: .utf8)
            return try await MainActor.run {
                guard let model = EditorSceneFileLoader.model(from: content) else {
                    throw EditorRuntimeSceneNavigationError.invalidScene(path)
                }
                let scene = Scene(name: model.scene.name)
                let result = EditorSceneFileLoader.load(model: model, into: scene.world, sourceURL: url, resourceRootURL: assetsDirectory)
                guard result.warnings.isEmpty else {
                    throw EditorRuntimeSceneNavigationError.invalidScene(result.warnings.joined(separator: "\n"))
                }
                return scene
            }
        }
        let scene = Scene(name: sceneModel.scene.name)
        let result = EditorSceneFileLoader.load(model: sceneModel, into: scene.world, resourceRootURL: assetsDirectory)
        navigator.installInitialScene(scene, make: {
            let scene = Scene(name: sceneModel.scene.name)
            _ = EditorSceneFileLoader.load(model: sceneModel, into: scene.world, resourceRootURL: assetsDirectory)
            return scene
        })
        if result.warnings.isEmpty {
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
