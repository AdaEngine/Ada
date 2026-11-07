import AdaAssets
@testable import AdaScene
import Testing

@Suite("Terrain height residency staging")
struct TerrainHeightResidencyTests {
    private func resources(_ storage: TerrainHeightStorage) throws -> [TerrainRegionAsset] {
        try storage.resourceCoordinates.compactMap { try storage.regionAsset(at: $0) }
    }

    @Test("Normal-only halo topology retains canonical derivatives while visible regions enter and leave")
    func haloNormalsAndRevisions() throws {
        let authored = try TerrainHeightStorage()
        let first = TerrainRegionCoordinate(x: 0, z: 0), second = TerrainRegionCoordinate(x: 1, z: 0)
        try authored.allocateRegion(at: first)
        try authored.allocateRegion(at: second)
        try authored.setHeight(1, at: .init(x: 255, z: 32))
        try authored.setHeight(2, at: .init(x: 256, z: 32))
        try authored.setHeight(5, at: .init(x: 257, z: 32))
        let regions = try resources(authored)
        let storage = try TerrainHeightStorage()
        let initial = try storage.residencySnapshot(regions: regions, visible: [first], expectedRevision: 0)
        try storage.commitResidency(initial, expectedRevision: 0)
        let edge = try #require(storage.snapshot(of: .init(x: 3, z: 0)))
        let canonical = try #require(authored.snapshot(of: .init(x: 3, z: 0)))
        #expect(edge.normals == canonical.normals)
        #expect(storage.height(atSample: .init(x: 256, z: 32)) == 2)
        #expect(storage.height(atSample: .init(x: 257, z: 32)) == nil)
        #expect(!storage.hasDirtyTiles)
        let revision = storage.revision
        let expanded = try storage.residencySnapshot(regions: regions, visible: [first, second], expectedRevision: revision)
        #expect(expanded.tileRevision(at: .init(x: 3, z: 0)) == edge.revision)
        try storage.commitResidency(expanded, expectedRevision: revision)
        let expandedRevision = storage.revision
        let moved = try storage.residencySnapshot(regions: regions, visible: [second], expectedRevision: expandedRevision)
        try storage.commitResidency(moved, expectedRevision: expandedRevision)
        #expect(storage.regionCoordinates == [second])
        #expect(storage.height(atSample: .init(x: 255, z: 32)) == nil)
        let secondEdge = try #require(storage.snapshot(of: .init(x: 4, z: 0)))
        #expect(secondEdge.normals == authored.snapshot(of: .init(x: 4, z: 0))?.normals)
    }

    @Test("Stale or over-budget staging leaves concurrent authored data intact")
    func rejectsStaleAndOverBudget() throws {
        let storage = try TerrainHeightStorage()
        let region = TerrainRegionCoordinate(x: 0, z: 0)
        try storage.allocateRegion(at: region)
        let revision = storage.revision
        let staged = try storage.residencySnapshot(regions: try resources(storage), visible: [], expectedRevision: revision)
        try storage.setHeight(9, at: .init(x: 10, z: 10))
        #expect(throws: TerrainHeightStorage.StorageError.self) { try storage.commitResidency(staged, expectedRevision: revision) }
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == 9)
        #expect(storage.regionCoordinates == [region])
        let limited = try TerrainHeightStorage(memoryBudgetBytes: 0)
        #expect(throws: TerrainHeightStorage.StorageError.self) {
            try limited.residencySnapshot(regions: try resources(storage), visible: [region], expectedRevision: 0)
        }
        #expect(limited.revision == 0 && limited.tileCoordinates.isEmpty && limited.residentHeightBytes == 0)
    }
}
