import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Opt-in committed queries hit native terrain tunnel floors, ceilings and ledges without physics enabled")
    func surfaceQueriesMatchPublishedVolume() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try await surfaceQueryFixture(folder)
        let app = try await makeApp()
        let owner = app.main.spawn("Queryable terrain") {
            Transform(); Terrain3DSource(source: file.path, streamingRadius: nil, queries: .init())
        }
        await settle(app)
        let surface = try #require(owner.components[Terrain3DSourceSurface.self])
        let query = try #require(surface.queries, "An enabled source must publish acceleration with its visible surface")
        #expect(query.revision == surface.storage.revision && query.tileCount == 1 && query.chargedBytes > 0)
        let floor = try #require(try query.raycast(.init(origin: [0, -4, 0], direction: [0, -2, 0])))
        let ceiling = try #require(try query.raycast(.init(origin: [0, -4, 0], direction: [0, 2, 0])))
        #expect(abs(floor.position.y + 6.5) < 0.05 && floor.normal.y > 0.9)
        #expect(abs(ceiling.position.y + 1.5) < 0.05 && ceiling.normal.y < -0.9)
        let ledge = try #require(try query.closest(to: [12, 3.8, 0], maximumDistance: 1))
        #expect(abs(ledge.position.y - 3.5) < 1e-5 && abs(ledge.distance - 0.3) < 1e-5)
        #expect(try query.raycast(.init(origin: [100, 10, 100], direction: [0, -1, 0])) == nil)
        #expect(throws: TriangleSurfaceQueryError.workBudgetExceeded) { try query.raycast(.init(origin: [0, 10, 0], direction: [0, -1, 0]), maximumWork: 0) }
    }

    @Test("Query budget failure keeps the previous committed indices and disabling acceleration releases them without replacing render buffers")
    func surfaceQueriesRollbackAndDisable() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try await surfaceQueryFixture(folder)
        let app = try await makeApp()
        var source = Terrain3DSource(source: file.path, streamingRadius: nil, queries: .init())
        let owner = app.main.spawn("Queryable terrain") { Transform(); source }
        await settle(app)
        let before = try #require(owner.components[Terrain3DSourceSurface.self]?.queries)
        let generation = try #require(before.tileGeneration(at: .init(x: 0, z: 0))), render = try buffers(owner)
        source.queries = .init(maximumResidentBytes: 0)
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.error != nil)
        #expect(owner.components[Terrain3DSourceSurface.self]?.queries?.tileGeneration(at: .init(x: 0, z: 0)) == generation)
        #expect(try buffers(owner) == render)
        source.queries = nil; owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(owner.components[Terrain3DSourceSurface.self]?.queries == nil)
        #expect(try buffers(owner) == render)
        #expect(try before.closest(to: [12, 3.8, 0], maximumDistance: 1) != nil, "A retained immutable query snapshot remains valid after source acceleration is disabled")
    }

    func surfaceQueryFixture(_ folder: URL, resolution: Int = 65) async throws -> URL {
        let storage = try TerrainHeightStorage(importing: Terrain3D(resolution: resolution, size: Float(resolution - 1)))
        var regions: [TerrainRegionAsset] = []
        for coordinate in storage.resourceCoordinates {
            if let region = try storage.regionAsset(at: coordinate) { regions.append(region) }
        }
        let operations: [TerrainVolumeOperation] = [
            .init(
                operation: .subtract,
                operand: .primitive(.capsule(radius: 2.5, halfHeight: 32)),
                transform: .init(translation: [0, -4, 0], rotation: Quat(axis: [0, 0, 1], angle: .pi / 2), scale: .one)
            ),
            .init(operation: .union, operand: .primitive(.box(halfExtents: [5, 0.5, 2])), transform: .init(translation: [12, 3, 0]))
        ]
        let file = folder.appendingPathComponent("world.aterrain")
        _ = try await AssetsManager.saveTerrainRegions(
            regions,
            manifest: .init(spacing: storage.spacing, originX: storage.origin.x, originZ: storage.origin.y),
            at: file.path,
            volume: .init(document: .init(cellSize: 1, origin: [storage.origin.x, 0, storage.origin.y], operations: operations), bricks: [])
        )
        return file
    }
}
