import AdaAssets
@testable import AdaScene
import Testing

@Suite("Terrain hidden surface pruning")
struct TerrainSurfacePruningTests {
    @Test("Removing visible geometry preserves authored channels on a normal-only neighbor")
    func preservesNormalOnlySurfaceRows() throws {
        let samples: [TerrainRegionSurfaceSample] = [.init(x: 0, z: 32, tintStrength: 1), .init(x: 32, z: 32, roughnessStrength: 1)]
        let masks: [TerrainRegionRuleMaskSample] = [.init(x: 0, z: 32, maskID: 9, value: 1), .init(x: 32, z: 32, maskID: 9, value: 0.25)]
        let left = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 3, z: 0)], pages: [])
        let right = TerrainRegionAsset(x: 1, z: 0, tiles: [.init(x: 0, z: 0)], pages: [], surface: samples, ruleMasks: masks)
        let storage = try TerrainHeightStorage(regions: [left, right])
        let candidate = try storage.residencySnapshot(
            regions: [left, right], visible: [.init(x: 0, z: 0)], expectedRevision: storage.revision
        )
        try storage.commitResidency(candidate, expectedRevision: storage.revision)
        try #require(storage.tileCoordinates == [.init(x: 3, z: 0)])
        let hiddenCell = TerrainTileCoordinate(x: 4, z: 0)
        let generation = try #require(storage.surfaceSnapshot().cells[hiddenCell]?.id)
        let charged = storage.residentSurfaceBytes
        try #require(try storage.removeRegion(at: .init(x: 0, z: 0)))
        try #require(storage.normalForBrush(at: .init(x: 288, z: 32), includeNormalCoverage: true) != nil)
        let retained = try #require(try storage.regionAsset(at: .init(x: 1, z: 0)))
        #expect(retained.surface == samples && retained.ruleMasks == masks)
        #expect(storage.surfaceSnapshot().cells[hiddenCell]?.id == generation)
        #expect(storage.residentSurfaceBytes == charged)
        #expect(storage.tileCoordinates.isEmpty)
    }
}
