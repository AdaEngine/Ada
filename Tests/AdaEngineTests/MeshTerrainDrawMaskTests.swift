@_spi(Internal) @testable import AdaApp
import AdaCorePipelines
import AdaECS
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaTransform
import Math
import Testing

@MainActor @Suite("Retained mesh source draw ownership", .serialized)
struct MeshTerrainDrawMaskTests {
    @Test func edgeCacheTracksExactTriangleContentsWhenBufferAndCountAreReused() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let device = unsafe RenderEngine.shared.renderDevice
        var triangle = MeshDescriptor(name: "Changing triangle indices")
        triangle.positions = .init([Vector3(-1, 0, 0), [1, 0, 0], [0, 1, 0]])
        triangle.indicies = [0, 1, 2]
        let source = try #require(Mesh.generate(from: [triangle], renderDevice: device).models.first?.parts.first?.indexBuffer)
        var cache = Wireframe3DResources()
        let initialBuffer = cache.indices(source: source, triangles: [0, 1, 2], device: device)
        let first = try #require(initialBuffer)
        let changedBuffer = cache.indices(source: source, triangles: [0, 2, 1], device: device)
        let changed = try #require(changedBuffer)
        #expect(ObjectIdentifier(first) != ObjectIdentifier(changed))
        let retainedBuffer = cache.indices(source: source, triangles: [0, 2, 1], device: device)
        let retained = try #require(retainedBuffer)
        #expect(ObjectIdentifier(retained) == ObjectIdentifier(changed))
        #expect(cache.allocatedBytes <= 64 * 1_024 * 1_024)
    }

    @Test func selectedPartsDisappearFromEveryExtractedPassAndRestoreWithoutEditingSourceAssets() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let device = unsafe RenderEngine.shared.renderDevice
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        let render = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
        render.insertResource(MainWorld(world: app.main))
        var triangle = MeshDescriptor(name: "Retained trunk")
        triangle.positions = .init([Vector3(-1, 0, 0), [1, 0, 0], [0, 1, 0]])
        triangle.indicies = [0, 1, 2]
        let mesh = Mesh.generate(from: [triangle, triangle], renderDevice: device)
        let material = PBRMaterial()
        let owner = app.main.spawn("Terrain")
        let tree = app.main.spawn("Editable tree") {
            Mesh3DComponent(mesh: mesh, materials: [material]); GlobalTransform(matrix: .identity)
        }
        func source() throws -> Mesh3DRenderSource {
            try #require(render.getResource(ExtractedMesh3DSources.self)?.meshes.first { $0.entity == tree.id })
        }
        await render.runScheduler(.extract)
        let original = try source()
        tree.components[MeshTerrain3DSourceMask.self] = .init(owner: owner.id, parts: [.init(model: 0, part: 0)])
        await render.runScheduler(.extract)
        let joined = try source()
        #expect(joined.mesh.models[0].parts[0].indexCount == 0)
        #expect(joined.mesh.models[0].parts[1].indexCount == 3)
        #expect(tree.components[Mesh3DComponent.self]?.mesh.models[0].parts[0].indexCount == 3)
        #expect(ObjectIdentifier(joined.mesh.models[0].parts[1].vertexBuffer) == ObjectIdentifier(original.mesh.models[0].parts[1].vertexBuffer))
        tree.components.remove(MeshTerrain3DSourceMask.self)
        await render.runScheduler(.extract)
        #expect(try source().mesh.models[0].parts.map(\.indexCount) == [3, 3])
        tree.components[Visibility.self] = .hidden
        tree.components[MeshTerrain3DSourceMask.self] = .init(owner: owner.id)
        await render.runScheduler(.extract)
        tree.components.remove(MeshTerrain3DSourceMask.self)
        await render.runScheduler(.extract)
        #expect(render.getResource(ExtractedMesh3DSources.self)?.meshes.isEmpty == true)
        #expect(tree.components[Visibility.self] == .hidden)
    }
}
