@_spi(Internal) import AdaRender
@testable import AdaScene
import Math
import Testing

@Suite("Sparse terrain heights")
struct TerrainHeightStorageTests {
    @Test("Canonical corner samples are shared by four regions and dirty only neighboring tiles")
    func sharedCornersAndNegativeCoordinates() throws {
        let storage = try TerrainHeightStorage()
        for z in -1...0 {
            for x in -1...0 { #expect(try storage.allocateRegion(at: .init(x: x, z: z))) }
        }
        #expect(storage.tileCoordinates.count == 64)
        #expect(storage.takeDirtyTiles(limit: 1_000).count == 64)
        #expect(try storage.setHeight(4, at: .init(x: 0, z: 0)))
        #expect(
            Set(storage.takeDirtyTiles(limit: 100)) == [
                .init(x: -1, z: -1), .init(x: 0, z: -1), .init(x: -1, z: 0), .init(x: 0, z: 0),
            ]
        )
        for z in -1...0 {
            for x in -1...0 {
                let snapshot = try #require(storage.snapshot(of: .init(x: x, z: z)))
                let sx = x == -1 ? 64 : 0, sz = z == -1 ? 64 : 0
                #expect(snapshot.heights[sz * 65 + sx] == 4)
                #expect(snapshot.normals[sz * 65 + sx] == Vector3(0, 1, 0))
            }
        }
        #expect(storage.regionCoordinates.count == 4)
        #expect(storage.residentHeightBytes == 64 * 64 * 4)
    }

    @Test("Snapshots stay immutable and remote tile revisions do not change after a local write")
    func revisionsAndNoOpWrites() throws {
        let storage = try TerrainHeightStorage()
        _ = try storage.allocateRegion(at: .init(x: 0, z: 0))
        _ = try storage.allocateRegion(at: .init(x: 2, z: 0))
        _ = storage.takeDirtyTiles(limit: 1_000)
        let old = try #require(storage.snapshot(of: .init(x: 0, z: 0)))
        let remote = try #require(storage.snapshot(of: .init(x: 8, z: 0)))
        #expect(try storage.setHeight(3, at: .init(x: 10, z: 10)))
        #expect(storage.takeDirtyTiles(limit: 10) == [.init(x: 0, z: 0)])
        let changed = try #require(storage.snapshot(of: .init(x: 0, z: 0)))
        #expect(changed.heights[10 * 65 + 10] == 3)
        #expect(old.heights[10 * 65 + 10] == 0)
        #expect(changed.revision != old.revision)
        #expect(storage.tileRevision(at: .init(x: 8, z: 0)) == remote.revision)
        #expect(!(try storage.setHeight(3, at: .init(x: 10, z: 10))))
        #expect(!storage.hasDirtyTiles)
        #expect(storage.tileRevision(at: .init(x: 0, z: 0)) == changed.revision)
    }

    @Test("Sample page budgets and invalid edits fail before changing stored terrain")
    func budgetsAndInvalidInputs() throws {
        let storage = try TerrainHeightStorage(memoryBudgetBytes: 64 * 64 * 4)
        _ = try storage.allocateRegion(at: .init(x: 0, z: 0))
        #expect(try storage.setHeight(2, at: .init(x: 10, z: 10)))
        #expect(throws: TerrainHeightStorage.StorageError.self) { try storage.setHeight(5, at: .init(x: 70, z: 10)) }
        #expect(storage.height(atSample: .init(x: 70, z: 10)) == 0)
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == 2)
        #expect(throws: TerrainHeightStorage.StorageError.self) { try storage.setHeight(.nan, at: .init(x: 10, z: 10)) }
        #expect(throws: TerrainHeightStorage.StorageError.self) { try storage.allocateRegion(at: .init(x: Int.max, z: 0)) }
        #expect(throws: TerrainHeightStorage.StorageError.self) { try storage.setHeight(2, at: .init(x: 4_096, z: 10)) }
        #expect(throws: TerrainHeightStorage.StorageError.self) { try TerrainHeightStorage(spacing: 0) }
        #expect(storage.residentHeightBytes == 64 * 64 * 4)
    }

    @Test("Importing a legacy patch preserves positions, normals, heights and its partial footprint")
    func legacyImport() throws {
        var terrain = Terrain3D(resolution: 7, size: 12)
        for z in 0..<7 {
            for x in 0..<7 { terrain.heights[z * 7 + x] = Float(x + z * 2) / 10 }
        }
        let storage = try TerrainHeightStorage(importing: terrain)
        #expect(storage.tileCoordinates == [.init(x: 0, z: 0)])
        let snapshot = try #require(storage.snapshot(of: .init(x: 0, z: 0)))
        #expect(snapshot.cellCountX == 6 && snapshot.cellCountZ == 6)
        let actual = snapshot.meshDescriptor()
        let expected = try terrain.meshDescriptor()
        #expect(actual.positions.elements == expected.positions.elements)
        #expect(actual.indicies == expected.indicies)
        let normals = try #require(actual.normals?.elements)
        let expectedNormals = try #require(expected.normals?.elements)
        #expect(zip(normals, expectedNormals).allSatisfy { ($0 - $1).length < 0.00001 })
        for point: Vector2 in [[0, 0], [1.25, -2.5], [-6, -6], [6, 6]] {
            let value = try #require(storage.height(at: point))
            let original = try #require(terrain.surfaceHeight(at: point))
            #expect(abs(value - original) < 0.00001)
        }
        #expect(storage.height(at: [7, 0]) == nil)
    }

    @Test("Removing a region retains a neighboring region's shared edge and frees unused pages")
    func removalPreservesSharedBoundary() throws {
        let storage = try TerrainHeightStorage()
        _ = try storage.allocateRegion(at: .init(x: -1, z: 0))
        _ = try storage.allocateRegion(at: .init(x: 0, z: 0))
        #expect(try storage.setHeight(7, at: .init(x: 0, z: 10)))
        #expect(try storage.removeRegion(at: .init(x: 0, z: 0)))
        let edge = try #require(storage.snapshot(of: .init(x: -1, z: 0)))
        #expect(edge.heights[10 * 65 + 64] == 7)
        #expect(storage.height(atSample: .init(x: 0, z: 10)) == 7)
        #expect(try storage.removeRegion(at: .init(x: -1, z: 0)))
        #expect(storage.tileCoordinates.isEmpty)
        #expect(storage.residentHeightBytes == 0)
    }

    @Test("Concurrent edits to one sample page retain every write")
    func concurrentWrites() async throws {
        let storage = try TerrainHeightStorage()
        _ = try storage.allocateRegion(at: .init(x: 0, z: 0))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for x in 1...24 {
                group.addTask { _ = try storage.setHeight(Float(x), at: .init(x: x, z: 10)) }
            }
            try await group.waitForAll()
        }
        for x in 1...24 { #expect(storage.height(atSample: .init(x: x, z: 10)) == Float(x)) }
    }

    @Test("Undrained removed-tile history stays bounded independently of live regions and height-page bytes")
    func dirtyHistoryIsBounded() throws {
        let storage = try TerrainHeightStorage(memoryBudgetBytes: 0)
        for x in -2_049...2_048 {
            try storage.allocateRegion(at: .init(x: x, z: 0))
            try storage.removeRegion(at: .init(x: x, z: 0))
        }
        #expect(storage.tileCoordinates.isEmpty)
        #expect(storage.residentHeightBytes == 0)
        #expect(storage.takeDirtyTiles(limit: 100_000).count <= 65_536)
    }
}

extension TerrainHeightStorageTests {
    @Test("A dirty-queue overflow signals consumers to reconstruct their complete derived tile set")
    func dirtyOverflowResynchronizesConsumer() throws {
        let storage = try TerrainHeightStorage(memoryBudgetBytes: 0)
        let observed = storage.dirtyOverflowGeneration
        for x in -2_049...2_048 {
            try storage.allocateRegion(at: .init(x: x, z: 0))
            try storage.removeRegion(at: .init(x: x, z: 0))
        }
        try storage.allocateRegion(at: .init(x: 10, z: 0))
        let deltas = storage.takeDirtyTiles(limit: 100_000)
        #expect(storage.dirtyOverflowGeneration != observed)
        #expect(deltas.count <= 65_536)
        let reconstructed = Set(storage.tileCoordinates)
        #expect(reconstructed.count == 16)
        #expect(reconstructed.allSatisfy { storage.snapshot(of: $0) != nil })
    }
}
