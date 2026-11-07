import AdaAssets
@testable import AdaScene
import Testing

@Suite("Terrain surface storage budgets")
struct TerrainSurfaceStorageBudgetTests {
    @Test("Canonical field admission uses its own budget and snapshots retain the configured allowance")
    func surfaceStorageBudget() throws {
        let region = TerrainRegionAsset(
            x: 0,
            z: 0,
            tiles: [.init(x: 0, z: 0)],
            pages: [],
            surface: [.init(x: 32, z: 32, tintStrength: 1)],
            ruleMasks: [.init(x: 32, z: 32, maskID: 9, value: 0.25)]
        )
        let measured = try TerrainHeightStorage(regions: [region], memoryBudgetBytes: 0, instanceMemoryBudgetBytes: 0)
        let charge = measured.residentSurfaceBytes
        try #require(charge > 0)
        #expect(throws: TerrainHeightStorage.StorageError.self) {
            try TerrainHeightStorage(regions: [region], surfaceMemoryBudgetBytes: charge - 1)
        }
        #expect(throws: TerrainHeightStorage.StorageError.self) { try TerrainHeightStorage(surfaceMemoryBudgetBytes: -1) }
        let storage = try TerrainHeightStorage(regions: [region], surfaceMemoryBudgetBytes: charge)
        let copy = try storage.snapshotForBrush(expectedRevision: storage.revision)
        let candidate = try storage.residencySnapshot(regions: [region], visible: [.init(x: 0, z: 0)], expectedRevision: storage.revision)
        #expect(copy.surfaceMemoryBudgetBytes == charge && candidate.surfaceMemoryBudgetBytes == charge)
        #expect(copy.residentSurfaceBytes == charge && candidate.residentSurfaceBytes == charge)
        try storage.commitResidency(candidate, expectedRevision: storage.revision)
        try #require(try storage.removeRegion(at: .init(x: 0, z: 0)))
        #expect(storage.residentSurfaceBytes == 0 && storage.surfaceMemoryBudgetBytes == charge)
        #expect(copy.residentSurfaceBytes == charge)
    }
}
