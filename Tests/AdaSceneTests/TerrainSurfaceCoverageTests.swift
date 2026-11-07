import AdaAssets
@testable import AdaScene
import Testing

@Suite("Terrain cached surface coverage")
struct TerrainSurfaceCoverageTests {
    @Test("Coverage honors shared edges, corners, partial extents and negative canonical pages")
    func exactSurfaceCoverageBounds() throws {
        func rows(_ x: UInt8, _ z: UInt8, region: Int32 = 0) throws -> TerrainSurfaceStorageRows {
            let asset = TerrainRegionAsset(x: region, z: region, tiles: [], pages: [], surface: [.init(x: x, z: z, tintStrength: 1)])
            return try TerrainHeightStorage(regions: [asset]).surfaceSnapshot()
        }
        let interior = try rows(63, 63)
        #expect(interior.hasSurfaceOverrides(in: .init(x: 0, z: 0)))
        #expect(!interior.hasSurfaceOverrides(in: .init(x: 0, z: 0), cellCountX: 32, cellCountZ: 16))
        let edge = try rows(64, 0)
        #expect(edge.hasSurfaceOverrides(in: .init(x: 0, z: 0)))
        #expect(!edge.hasSurfaceOverrides(in: .init(x: 0, z: 0), cellCountX: 63))
        #expect(edge.hasSurfaceOverrides(in: .init(x: 1, z: 0)))
        #expect(!edge.hasSurfaceOverrides(in: .init(x: 0, z: 1)))
        let corner = try rows(64, 64)
        #expect(corner.hasSurfaceOverrides(in: .init(x: 0, z: 0)))
        #expect(!corner.hasSurfaceOverrides(in: .init(x: 0, z: 0), cellCountZ: 63))
        #expect(corner.hasSurfaceOverrides(in: .init(x: 1, z: 1)))
        let negative = try rows(255, 255, region: -1)
        #expect(negative.hasSurfaceOverrides(in: .init(x: -1, z: -1)))
        #expect(!negative.hasSurfaceOverrides(in: .init(x: -1, z: -1), cellCountX: 32, cellCountZ: 32))
        #expect(!negative.hasSurfaceOverrides(in: .init(x: 0, z: -1)))
    }
}
