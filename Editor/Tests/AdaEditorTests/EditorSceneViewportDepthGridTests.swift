@_spi(AdaEngine) import AdaEngine
// Mesh part topology is exposed through the renderer's Internal SPI.
// swiftlint:disable:next duplicate_imports
@_spi(Internal) import AdaEngine
import Testing

@testable import AdaEditor

@Suite("Editor 3D depth grid")
@MainActor
struct EditorSceneViewportDepthGridTests {
    @Test("Grid installs after renderer setup and uses drawable triangles")
    func gridInstallsAfterRendererSetup() async throws {
        let world = World(name: "DepthGrid")
        world.setSchedulers([.preUpdate])
        world.addSystem(TransformSystem.self, on: .preUpdate)
        let app = AppWorlds(main: world)
        app.updateScheduler = .preUpdate
        app
            .addPlugin(TransformPlugin())
            .addPlugin(RenderWorldPlugin())
            .addPlugin(CameraPlugin())
            .addPlugin(VisibilityPlugin())
            .addPlugin(SpritePlugin())
            .addPlugin(Mesh2DPlugin())
            .addPlugin(Model3DPlugin())
            .addPlugin(Core2DPlugin())
            .addPlugin(Core3DPlugin(includes2D: true))
            .addPlugin(UpscalePlugin())
        app.insertResource(OffscreenRenderWorld())
        app.insertResource(PrimaryWindowId(windowId: RID()))

        let viewport = EditorSceneViewportModel()
        viewport.attachSceneWorld(world, loadResult: .empty)
        viewport.setDisplayMode(.threeD)
        #expect(world.getEntities().allSatisfy { !$0.name.hasPrefix("EditorViewportGrid_") })

        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
        }
        try await app.build()
        let target = RenderTexture(size: SizeInt(width: 128, height: 128), scaleFactor: 1, format: .bgra8)
        let displayCamera = world.spawn("SceneView_Camera") {
            Camera(renderTarget: target)
            Transform()
            VisibleEntities()
            Visibility.visible
        }
        viewport.setViewportSize(Size(width: 128, height: 128))
        _ = viewport.update(deltaTime: 0.5)

        let grid = world.getEntities().filter { $0.name.hasPrefix("EditorViewportGrid_") }
        #expect(grid.count == 5)
        for entity in grid {
            let part = try #require(entity.components[Mesh2D.self]?.mesh.models.first?.parts.first)
            #expect(part.primitiveTopology == .triangleList)
            #expect(part.indexCount > 0)
            #expect(part.indexCount.isMultiple(of: 3))
            #expect(entity.components[Visibility.self] == .visible)
        }

        let renderWorld = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
        let diagnostics = try #require(renderWorld.getResource(RenderGraphDiagnostics.self))
        diagnostics.configure(isEnabled: true)
        try await app.update()
        try await app.update()
        let gridIDs = Set(grid.map(\.id))
        let extracted = try #require(renderWorld.getResource(ExctractedMeshes2D.self))
        #expect(Set(extracted.meshes.map(\.entityId)).intersection(gridIDs).count == 5)
        #expect(displayCamera.components[VisibleEntities.self]?.entityIds.isSuperset(of: gridIDs) == true)
        let items = try #require(renderWorld.getResource(SortedRenderItems<Transparent2DRenderItem>.self))
        #expect(items.items.items.filter { $0.drawPass is Mesh2DDrawPass }.count == 5)
        let frame = try #require(diagnostics.recentFrames().first { $0.graphLabel == RenderGraph.Label.main3D.rawValue })
        #expect(frame.executionOrder.contains(Scene2DRenderNode.name.rawValue))
        #expect(frame.error == nil)

        viewport.setDisplayMode(.twoD)
        #expect(grid.allSatisfy { $0.components[Visibility.self] == .hidden })
    }
}
