@_spi(Internal) @testable import AdaApp
import AdaAssets
import AdaECS
import AdaGeometry
import AdaPhysics
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaTransform
import Foundation
import Math
import Testing

@MainActor @Suite("Mesh Terrain fixed step", .serialized)
struct MeshTerrainFixedStepTests {
    @Test("Play resumes native fixed steps after the compiled joined collider is ready",
          .enabled(if: TriangleMeshBoolean.isAvailable))
    func meshTerrainUnblocksPhysicsAfterColliderPublication() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeshTerrainPlay-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ground = try TriangleSurface.ground(size: [12, 8], cells: 6)
        let rock = try TriangleSurface.box(minimum: [-1, -1, -1], maximum: [1, 2, 1])
        let document = MeshTerrainDocument(sections: [.init(surface: ground, closure: .ground(bottomHeight: -4))],
            modifiers: [.init(sourceID: 1, operation: .union, surface: rock)])
        let asset = try await MeshTerrainDocumentAsset(document: document).compiling()
        let file = directory.appendingPathComponent("world.aterrain")
        try asset.encodedData().write(to: directory.appendingPathComponent("world.atmesh"))
        try TerrainManifestAsset(meshDocumentFileName: "world.atmesh").encodedData().write(to: file)
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin()).addPlugin(Physics3DPlugin())
        try await app.build()
        app.main.insertResource(FixedTime(deltaTime: 1 / 60))
        let owner = app.main.spawn("Terrain") { Transform(); Terrain3DSource(source: file.path, generatesCollision: true) }
        let sphere = app.main.spawn("Play test sphere") {
            Transform(position: [0, 5, 0])
            PhysicsBody3DComponent(shapes: [.generateSphere(radius: 0.4)], mass: 1, mode: .dynamic)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while owner.components[MeshTerrain3DSourceSurface.self] == nil, ContinuousClock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(owner.components[MeshTerrain3DSourceSurface.self] != nil)
        await app.main.runScheduler(.physicsSync)
        for _ in 0..<120 {
            await app.main.runScheduler(.physicsStep)
            await app.main.runScheduler(.physicsWriteback)
        }
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        let height = try #require(sphere.components[Transform.self]?.position.y)
        #expect(height > 2.3 && height < 2.5)
    }
}
