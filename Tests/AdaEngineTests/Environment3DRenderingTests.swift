import AdaEngine
@_spi(Internal) @testable import AdaApp
@_spi(Internal) @testable import AdaRender
import Testing

@MainActor
@Suite("3D environment rendering")
struct Environment3DRenderingTests {

    @Test("Render world installs every scheduler in its default order")
    func renderWorldInstallsEveryDefaultScheduler() async throws {
        try Self.setupHeadlessRenderEngineIfNeeded()

        let app = AppWorlds(main: World())
        app
            .addPlugin(MainSchedulerPlugin())
            .addPlugin(RenderWorldPlugin())

        try await app.build()

        let renderWorld = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
        #expect(renderWorld.schedulers.getScheduler(.batching) != nil)
    }

    @Test("Core3D plugin installs directional shadow and SSR render passes")
    func core3DPluginInstallsDirectionalShadowAndSSRPasses() async throws {
        try Self.setupHeadlessRenderEngineIfNeeded()

        let app = AppWorlds(main: World())
        app
            .addPlugin(MainSchedulerPlugin())
            .addPlugin(RenderWorldPlugin())
            .addPlugin(Core3DPlugin())

        try await app.build()

        let renderWorld = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
        let graph = try #require(renderWorld.getResource(RenderGraph.self)?.getSubgraph(by: .main3D))
        let snapshot = graph.makeSnapshot(includeSubgraphs: false)
        #expect(snapshot.nodes.contains { $0.label == DirectionalShadow3DRenderNode.name.rawValue })
        #expect(snapshot.nodes.contains { $0.label == RenderNodeLabel.screenSpaceReflection.rawValue })
        #expect(snapshot.edges.contains {
            $0.fromNode == DirectionalShadow3DRenderNode.name.rawValue
                && $0.toNode == Main3DRenderNode.name.rawValue
        })
        #expect(snapshot.edges.contains {
            $0.fromNode == Main3DRenderNode.name.rawValue
                && $0.toNode == RenderNodeLabel.screenSpaceReflection.rawValue
        })
    }

    @Test("Camera3D exposes skybox and soft SSR defaults")
    func camera3DEnvironmentDefaults() {
        let camera = Camera3D(camera: Camera())

        #expect(camera.environment.skybox.isEnabled)
        #expect(camera.environment.screenSpaceReflection.isEnabled)
        #expect(camera.environment.screenSpaceReflection.maxSteps <= 64)
        #expect(camera.environment.screenSpaceReflection.intensity < 1)
    }

    private static func setupHeadlessRenderEngineIfNeeded() throws {
        guard unsafe RenderEngine.shared == nil else {
            return
        }

        unsafe RenderEngine.configurations.preferredBackend = .headless
        try RenderEngine.setupRenderEngine()
    }
}
