import AdaAssets
@testable import AdaScene
import Math
import Testing

@Suite("Terrain instance storage")
struct TerrainInstanceStorageTests {
    @Test("Restoring and editing heights preserves compact placement data in exported regions")
    func heightEditsRetainPlacements() throws {
        let record = try TerrainRegionInstance(id: 42, prototypeID: 7, localPosition: [1, 1, 1], flags: [])
        let region = TerrainRegionAsset(x: -1, z: 0, tiles: [.init(x: 0, z: 0)], pages: [], instances: [record])
        let storage = try TerrainHeightStorage(regions: [region])
        #expect(storage.residentInstanceBytes == MemoryLayout<TerrainRegionInstance>.stride)
        #expect(try storage.regionAsset(at: .init(x: -1, z: 0))?.instances == [record])
        try storage.setHeight(3, at: .init(x: -255, z: 1))
        let changed = try #require(try storage.regionAsset(at: .init(x: -1, z: 0)))
        #expect(changed.instances == [record])
        #expect(changed.pages.first?.samples[65] == 3)
        let restored = try TerrainHeightStorage(regions: [TerrainRegionAsset(data: changed.encodedData())])
        #expect(try restored.regionAsset(at: .init(x: -1, z: 0))?.instances == [record])
    }

    @Test("Placement-only data is retained as a resource and explicit removal clears it")
    func placementOnlyRegionLifecycle() throws {
        let record = try TerrainRegionInstance(id: 43, prototypeID: 7, localPosition: [1, 1, 1], flags: [])
        let region = TerrainRegionAsset(x: 1, z: 0, tiles: [], pages: [], instances: [record])
        let storage = try TerrainHeightStorage(regions: [region], memoryBudgetBytes: 0)
        #expect(storage.resourceCoordinates == [.init(x: 1, z: 0)])
        #expect(storage.revision > 0)
        #expect(try storage.regionAsset(at: .init(x: 1, z: 0))?.instances == [record])
        #expect(try storage.removeRegion(at: .init(x: 1, z: 0)))
        #expect(storage.resourceCoordinates.isEmpty)
        #expect(storage.residentInstanceBytes == 0)
    }

    @Test("Instance data has an independent byte budget and duplicate IDs cannot span loaded regions")
    func boundsRestoredPlacementData() throws {
        let record = try TerrainRegionInstance(id: 44, prototypeID: 7, localPosition: [1, 1, 1])
        let first = TerrainRegionAsset(x: 0, z: 0, tiles: [], pages: [], instances: [record])
        #expect(throws: (any Error).self) {
            try TerrainHeightStorage(regions: [first], memoryBudgetBytes: 0, instanceMemoryBudgetBytes: MemoryLayout<TerrainRegionInstance>.stride - 1)
        }
        let second = TerrainRegionAsset(x: 1, z: 0, tiles: [], pages: [], instances: [record])
        #expect(throws: (any Error).self) { try TerrainHeightStorage(regions: [first, second]) }
        let storage = try TerrainHeightStorage(regions: [first], memoryBudgetBytes: 0, instanceMemoryBudgetBytes: MemoryLayout<TerrainRegionInstance>.stride)
        #expect(storage.residentInstanceBytes == MemoryLayout<TerrainRegionInstance>.stride)
    }

    @Test("Normal-only residency retains placement payloads without exposing their height tiles")
    func residencyKeepsHiddenPlacementRecords() throws {
        let record = try TerrainRegionInstance(id: 45, prototypeID: 7, localPosition: [1, 1, 1])
        let first = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0)], pages: [])
        let second = TerrainRegionAsset(x: 1, z: 0, tiles: [.init(x: 0, z: 0)], pages: [], instances: [record])
        let storage = try TerrainHeightStorage(regions: [first, second])
        let candidate = try storage.residencySnapshot(regions: [first, second], visible: [.init(x: 0, z: 0)], expectedRevision: storage.revision)
        #expect(candidate.tileCoordinates == [.init(x: 0, z: 0)])
        let hidden = try #require(try candidate.regionAsset(at: .init(x: 1, z: 0)))
        #expect(hidden.tiles.isEmpty && hidden.instances == [record])
    }
}

extension TerrainInstanceStorageTests {
    @Test(
        "Positive-boundary placement resources can be removed while surface allocation remains exclusive",
        arguments: [
            TerrainRegionCoordinate(x: 4_096, z: 0), TerrainRegionCoordinate(x: 0, z: 4_096), TerrainRegionCoordinate(x: 4_096, z: 4_096),
        ]
    )
    func removesBoundaryPlacements(coordinate: TerrainRegionCoordinate) throws {
        let record = try TerrainRegionInstance(id: 60, prototypeID: 0, localPosition: .zero, flags: [])
        let region = TerrainRegionAsset(x: Int32(coordinate.x), z: Int32(coordinate.z), tiles: [], pages: [], instances: [record])
        let storage = try TerrainHeightStorage(regions: [region], memoryBudgetBytes: 0)
        let revision = storage.revision
        #expect((try? storage.removeRegion(at: coordinate)) == true)
        #expect(storage.residentInstanceBytes == 0 && storage.resourceCoordinates.isEmpty)
        #expect(storage.revision == revision + 1)
        #expect(throws: (any Error).self) { try storage.allocateRegion(at: coordinate) }
    }

    @Test("Removing boundary placements retains canonical height data needed by normal-only neighboring surfaces")
    func placementRemovalRetainsHiddenCanonicalHeights() throws {
        let record = try TerrainRegionInstance(id: 61, prototypeID: 0, localPosition: .zero, flags: [])
        let surface = TerrainRegionAsset(x: 4_095, z: 0, tiles: [.init(x: 3, z: 0)], pages: [])
        var samples = Array(repeating: Float(0), count: 4_096)
        samples[0] = 4
        let edge = TerrainRegionAsset(
            x: 4_096,
            z: 0,
            tiles: [],
            pages: [.init(x: 0, z: 0, samples: samples)],
            instances: [record]
        )
        let storage = try TerrainHeightStorage(regions: [surface, edge])
        let hidden = try storage.residencySnapshot(regions: [surface, edge], visible: [], expectedRevision: storage.revision)
        #expect((try? hidden.removeRegion(at: .init(x: 4_096, z: 0))) == true)
        let retained = try #require(try hidden.regionAsset(at: .init(x: 4_096, z: 0)))
        #expect(retained.instances.isEmpty && hidden.residentInstanceBytes == 0)
        #expect(retained.pages.first?.samples[0] == 4)
    }
}
