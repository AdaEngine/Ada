import AdaAssets
@testable import AdaScene
import Testing

@Suite("Terrain direct native budgets")
struct TerrainDirectNativeBudgetTests {
    @Test("Public storage mutations preserve a serializable region atomically", arguments: [false, true])
    func terrainDirectNativeBudget(allocation: Bool) throws {
        var surface: [TerrainRegionSurfaceSample] = [], instances: [TerrainRegionInstance] = []
        for z in 0..<256 {
            for x in 0..<256 { surface.append(.init(x: UInt8(x), z: UInt8(z), tintStrength: 1)) }
        }
        for index in 0..<(allocation ? 63_230 : 63_000) {
            instances.append(try .init(
                id: UInt64(index), prototypeID: 0, localPosition: [Float(index % 256) + 0.5, 0, Float(index / 256) + 0.5], flags: []
            ))
        }
        var pages: [TerrainRegionHeightPage] = [], tiles: [TerrainRegionTile] = []
        for index in 0..<9 {
            var values = [Float](repeating: 0, count: 4_096)
            values[0] = 1
            pages.append(.init(x: UInt8(index % 4), z: UInt8(index / 4), samples: values))
        }
        if !allocation { for z in 0..<4 { for x in 0..<4 { tiles.append(.init(x: UInt8(x), z: UInt8(z))) } } }
        let region = TerrainRegionAsset(x: 0, z: 0, tiles: tiles, pages: pages, instances: instances, surface: surface)
        let encoded = try region.encodedData()
        try #require(encoded.count < 8 * 1_024 * 1_024 && encoded.count > 8 * 1_024 * 1_024 - 16_384)
        let storage = try TerrainHeightStorage(regions: [region])
        let original = try #require(try storage.regionAsset(at: .init(x: 0, z: 0)))
        let revision = storage.revision, bytes = storage.residentHeightBytes, coordinates = storage.tileCoordinates
        #expect(throws: (any Error).self) {
            if allocation {
                try storage.allocateRegion(at: .init(x: 0, z: 0))
            } else {
                try storage.setHeight(2, at: .init(x: 64, z: 128))
            }
        }
        let retained = try #require(try storage.regionAsset(at: .init(x: 0, z: 0)))
        #expect(storage.revision == revision && storage.residentHeightBytes == bytes && storage.tileCoordinates == coordinates)
        #expect(retained.pages == original.pages && retained.tiles == original.tiles && retained.instances == original.instances)
        #expect(retained.surface == original.surface && retained.ruleMasks == original.ruleMasks)
    }
}
