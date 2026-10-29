import AdaEngine
import AdaSpine
import Foundation

enum EditorMovieMakerSource: Sendable {
    case project(URL, AdaProject)
    case scene(url: URL, assets: URL, runtime: EditorScenePlayRuntime?)

    @MainActor
    func prepare() async throws -> EditorMovieMakerRuntime {
        switch self {
        case let .project(url, project):
            let artifact = try await Self.build(project, at: url)
            return try EditorMovieMakerRuntime(artifact: artifact, projectURL: url)
        case let .scene(url, assets, runtime):
            return EditorMovieMakerRuntime(sceneURL: url, assets: assets, runtime: runtime)
        }
    }

    @concurrent
    private static func build(_ project: AdaProject, at url: URL) async throws -> EditorAdaScriptProjectBuildArtifact {
        try Task.checkCancellation()
        return try EditorAdaScriptProjectBuilder().prepare(project: project, at: url)
    }
}

/// Shares the project's Play configuration, but prepares scene assets before frame zero.
@MainActor
final class EditorMovieMakerRuntime {
    private let projectView: EditorAdaScriptProjectRuntimeView?
    private let sceneURL: URL?
    private let assetsDirectory: URL
    private let playRuntime: EditorScenePlayRuntime?
    private var preparedScene: EditorRuntimeScenePreparation?
    private var didPrepareScene = false
    private weak var app: AppWorlds?
    private var loadWarnings: [String] = []
    private var scriptPlugin: AdaScriptPlugin?

    init(artifact: EditorAdaScriptProjectBuildArtifact, projectURL: URL) throws {
        projectView = try EditorAdaScriptProjectRuntimeView(artifact: artifact)
        sceneURL = artifact.entry.scene.map { projectURL.appendingPathComponent($0) }
        assetsDirectory = artifact.assetsDirectory
        playRuntime = nil
    }

    init(sceneURL: URL, assets: URL, runtime: EditorScenePlayRuntime?) {
        projectView = nil
        self.sceneURL = sceneURL
        assetsDirectory = assets
        playRuntime = runtime
    }

    func configure(_ app: AppWorlds) throws {
        self.app = app
        app.runtimeLogSource = "Game"
        if let projectView {
            var worlds = app
            projectView.configureRuntime(&worlds, includesEntryScene: false)
            if !projectView.usesSceneCameras { app.spawn("MovieCamera", bundle: Camera2D()) }
            return
        }
        EditorComponentRegistry.registerBuiltIns()
        app.addPlugin(TransformPlugin())
            .addPlugin(InputPlugin(actions: playRuntime?.inputActions ?? []))
            .addPlugin(RenderWorldPlugin())
            .addPlugin(EventsPlugin())
            .addPlugin(CameraPlugin())
            .addPlugin(AssetsPlugin(directories: try EditorSceneViewportView.assetDirectories(for: assetsDirectory)))
            .addPlugin(VisibilityPlugin())
            .addPlugin(SpritePlugin())
            .addPlugin(Mesh2DPlugin())
            .addPlugin(SpinePlugin())
            .addPlugin(TextPlugin())
            .addPlugin(ScenePlugin())
            .addPlugin(Camera2DControllerPlugin())
            .addPlugin(ScriptableObjectPlugin())
            .addPlugin(Physics2DPlugin())
            .addPlugin(Physics3DPlugin())
            .addPlugin(TileMapPlugin())
            .addPlugin(Core2DPlugin())
            .addPlugin(Core3DPlugin(includes2D: true))
            .addPlugin(Light2DPlugin())
            .addPlugin(UpscalePlugin())
            .addPlugin(AudioPlugin())
        if let playRuntime {
            app.addPlugin(EditorProjectScriptObjectsPlugin(catalog: try playRuntime.makeScriptableCatalog()))
            scriptPlugin = try playRuntime.makeScriptPlugin()
            if let scriptPlugin { app.addPlugin(scriptPlugin) }
        }
        let ui = UIComponentRuntime(resourceRoot: assetsDirectory, catalog: .standard)
        ui.enableAdaScript(sourceRoot: EditorSceneViewportView.uiProjectRoot(from: assetsDirectory))
        app.insertResource(UIComponentRuntimeResource(ui))
    }

    func prepareScene(in world: World) async throws {
        let diagnostics = (projectView?.diagnostics ?? []) + (scriptPlugin?.diagnostics ?? [])
        if !diagnostics.isEmpty { throw EditorMovieMakerError.runtime(diagnostics.joined(separator: "\n")) }
        guard !didPrepareScene else { return }
        try Task.checkCancellation()
        if let sceneURL, let app {
            preparedScene = try await EditorRuntimeScenePreparation.prepare(at: sceneURL, assetsDirectory: assetsDirectory)
            guard let preparedScene else { return }
            let entry = EditorAdaScriptRuntimeEntryPlugin(
                sceneModel: preparedScene.model, assetsDirectory: assetsDirectory, sourceURL: sceneURL,
                recordsAchievement: false, onInitialSceneLoaded: { [weak self] result in self?.loadWarnings = result.warnings }
            )
            entry.setup(in: app)
            if !loadWarnings.isEmpty { throw EditorMovieMakerError.runtime(loadWarnings.joined(separator: "\n")) }
        }
        didPrepareScene = true
    }

    func finish() { projectView?.performanceSession.stop() }
}
