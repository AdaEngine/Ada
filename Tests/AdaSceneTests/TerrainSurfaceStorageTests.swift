import AdaAssets
@testable import AdaScene
import Testing

@Suite("Terrain canonical surface storage")
struct TerrainSurfaceStorageTests {
    @Test("Canonical paint and masks survive sparse import, height edits and immutable snapshots")
    func surfaceStorageRoundTrip() throws {
        let region = source()
        let storage = try TerrainHeightStorage(regions: [region])
        let first = try #require(try storage.regionAsset(at: .init(x: 0, z: 0)))
        #expect(first.surface == region.surface && first.ruleMasks == region.ruleMasks)
        let copy = try storage.snapshotForBrush(expectedRevision: storage.revision)
        try #require(try storage.setHeight(5, at: .init(x: 64, z: 64)))
        let edited = try #require(try storage.regionAsset(at: .init(x: 0, z: 0)))
        let captured = try #require(try copy.regionAsset(at: .init(x: 0, z: 0)))
        #expect(edited.surface == region.surface && edited.ruleMasks == region.ruleMasks)
        #expect(captured.surface == region.surface && captured.ruleMasks == region.ruleMasks)
        #expect(captured.pages.isEmpty && !edited.pages.isEmpty)
        let restored = try TerrainHeightStorage(regions: [TerrainRegionAsset(data: edited.encodedData())])
        #expect(try restored.regionAsset(at: .init(x: 0, z: 0))?.surface == region.surface)
    }

    @Test("Surface-only residency changes invalidate canonical material fields without changing heights")
    func surfaceResidencyRevision() throws {
        let original = source()
        let storage = try TerrainHeightStorage(regions: [original])
        let visible: Set<TerrainRegionCoordinate> = [.init(x: 0, z: 0)]
        let initial = try storage.residencySnapshot(regions: [original], visible: visible, expectedRevision: storage.revision)
        try storage.commitResidency(initial, expectedRevision: storage.revision)
        let previousRevision = storage.revision
        let previousHeights = try #require(storage.snapshot(of: .init(x: 0, z: 0))).heights
        let changed = source(tintStrength: 0.25)
        let next = try storage.residencySnapshot(regions: [changed], visible: visible, expectedRevision: previousRevision)
        #expect(next.revision > previousRevision)
        #expect(next.snapshot(of: .init(x: 0, z: 0))?.revision == next.revision)
        #expect(next.snapshot(of: .init(x: 0, z: 0))?.heights == previousHeights)
        try storage.commitResidency(next, expectedRevision: previousRevision)
        #expect(try storage.regionAsset(at: .init(x: 0, z: 0))?.surface == changed.surface)
        let stable = try storage.residencySnapshot(regions: [changed], visible: visible, expectedRevision: storage.revision)
        #expect(stable.revision == storage.revision)
    }

    @Test("Removing a region preserves shared canonical paint until its last adjacent surface disappears")
    func surfaceRegionPruning() throws {
        let sample = TerrainRegionSurfaceSample(x: 0, z: 32, tintStrength: 1)
        let mask = TerrainRegionRuleMaskSample(x: 0, z: 32, maskID: 9, value: 0.25)
        let left = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 3, z: 0)], pages: [])
        let right = TerrainRegionAsset(x: 1, z: 0, tiles: [.init(x: 0, z: 0)], pages: [], surface: [sample], ruleMasks: [mask])
        let storage = try TerrainHeightStorage(regions: [left, right])
        try #require(try storage.removeRegion(at: .init(x: 1, z: 0)))
        let retained = try #require(try storage.regionAsset(at: .init(x: 1, z: 0)))
        #expect(retained.tiles.isEmpty && retained.surface == [sample] && retained.ruleMasks == [mask])
        #expect(storage.resourceCoordinates.contains(.init(x: 1, z: 0)))
        try #require(try storage.removeRegion(at: .init(x: 0, z: 0)))
        #expect(try storage.regionAsset(at: .init(x: 1, z: 0)) == nil)
        #expect(storage.resourceCoordinates.isEmpty)
    }

    private func source(tintStrength: Float = 0.75) -> TerrainRegionAsset {
        .init(
            x: 0,
            z: 0,
            tiles: [.init(x: 0, z: 0)],
            pages: [],
            surface: [.init(x: 64, z: 64, layerIDs: [7, 12, 0, 0], weights: [0.25, 0.75, 0, 0], overrideStrength: 0.625, tintStrength: tintStrength)],
            ruleMasks: [.init(x: 64, z: 64, maskID: 9, value: 0.25)]
        )
    }
}
