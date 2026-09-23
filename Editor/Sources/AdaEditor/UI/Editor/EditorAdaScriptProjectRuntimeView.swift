@_spi(AdaEngine) import AdaEngine
import Foundation

enum EditorAdaScriptRuntimeError: Error, LocalizedError {
    case windowManagerUnavailable

    var errorDescription: String? {
        switch self {
        case .windowManagerUnavailable:
            "AdaScript runtime cannot create a window because the window manager is unavailable."
        }
    }
}

@MainActor
struct EditorAdaScriptProjectRuntimeView: View {
    let performanceSession = EditorGamePerformanceSession()
    private let artifact: EditorAdaScriptProjectBuildArtifact
    private let entryView: AdaScriptView?
    private let scriptPlugin: AdaScriptPlugin?

    init(artifact: EditorAdaScriptProjectBuildArtifact) throws {
        self.artifact = artifact
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
        ZStack {
            SceneView(
                make: { app in
                    configureRuntime(&app)
                },
                updateContent: { _, _ in }
            )
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)

            if let entryView {
                entryView
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
        }
        .background(.black)
        .onDisappear { performanceSession.stop() }
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

private struct EditorAdaScriptRuntimeEntryPlugin: Plugin {
    let sceneModel: EditorSceneModel
    let assetsDirectory: URL

    func setup(in app: borrowing AppWorlds) {
        let result = EditorSceneFileLoader.load(model: sceneModel, into: app.main, resourceRootURL: assetsDirectory)
        if result.warnings.isEmpty {
            EditorAchievementBootstrap.center?.record(EditorAchievementRules.playedScene(sceneModel, adaScript: true))
        }
    }
}
