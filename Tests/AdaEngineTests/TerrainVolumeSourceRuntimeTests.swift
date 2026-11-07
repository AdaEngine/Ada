import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Source loading publishes a tunnel floor and elevated ledge in both real mesh buffers and native collision")
    func volumeSourcePublishesGeometryAndCollision() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = try TerrainHeightStorage(importing: Terrain3D(resolution: 65, size: 64))
        var regions: [TerrainRegionAsset] = []
        for coordinate in storage.resourceCoordinates {
            if let region = try storage.regionAsset(at: coordinate) { regions.append(region) }
        }
        let cut = TerrainVolumeOperation(
            operation: .subtract,
            operand: .primitive(.capsule(radius: 2.5, halfHeight: 32)),
            transform: .init(translation: [0, -4, 0], rotation: Quat(axis: [0, 0, 1], angle: .pi / 2), scale: .one)
        )
        let add = TerrainVolumeOperation(
            operation: .union,
            operand: .primitive(.box(halfExtents: [5, 0.5, 2])),
            transform: .init(translation: [12, 3, 0])
        )
        let file = folder.appendingPathComponent("world.aterrain")
        _ = try await AssetsManager.saveTerrainRegions(
            regions,
            manifest: .init(spacing: storage.spacing, originX: storage.origin.x, originZ: storage.origin.y),
            at: file.path,
            volume: .init(document: .init(cellSize: 1, origin: [-32, 0, -32], operations: [cut, add]), bricks: [])
        )
        let app = try await makeApp(physics: true)
        let owner = app.main.spawn("Hybrid terrain") {
            Transform(); Terrain3DSource(source: file.path, streamingRadius: nil)
        }
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        let positions = owner.children.flatMap { child in
            child.components[Mesh3DComponent.self]?.mesh.models.flatMap { model in model.parts.flatMap { $0.meshDescriptor.positions.elements } } ?? []
        }
        #expect(positions.contains { $0.y < -2 }, "Published render geometry must include the cut tunnel")
        #expect(positions.contains { $0.y > 2 }, "Published render geometry must include the elevated union")
        await app.main.runScheduler(.physicsSync)
        let physics = try #require(app.main.physicsWorld3D)
        let floor = physics.sphereCastFraction(from: [0, -4, 0], to: [0, -10, 0], radius: 0.1)
        #expect(floor > 0.35 && floor < 0.5, "Native collision must include the carved floor rather than just the old heightfield")
        let ledge = physics.sphereCastFraction(from: [12, 8, 0], to: [12, 2, 0], radius: 0.1)
        #expect(ledge > 0.65 && ledge < 0.8, "Native collision must match the added visible ledge")
    }
}
