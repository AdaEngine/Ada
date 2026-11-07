import AdaAssets
@testable import AdaScene
import Foundation
import Math
import Testing

@Suite("Sparse immutable terrain volume cache")
struct TerrainVolumeCacheTests {
    private let near = TerrainVolumeBrickCoordinate(x: 0, y: 0, z: 0)
    private let far = TerrainVolumeBrickCoordinate(x: 8, y: 0, z: 0)

    private func base() throws -> TerrainHeightStorage {
        let source = try TerrainHeightStorage()
        _ = try source.allocateRegion(at: .init(x: 0, z: 0))
        _ = try source.allocateRegion(at: .init(x: 1, z: 0))
        return source
    }

    @Test("Unchanged base and operations reuse exact brick generations")
    func unchangedReuse() throws {
        let source = try base(), document = TerrainVolumeDocumentAsset(cellSize: 1)
        let field = try TerrainVolumeField(document: document, base: source)
        let empty = try TerrainVolumeCache(maximumBricks: 2)
        let first = try #require(try? empty.preparing(field: field, required: [far, near]), "A bounded sparse cache must prepare requested bricks")
        #expect(empty.coordinates.isEmpty)
        #expect(first.builtBrickCount == 2 && first.reusedBrickCount == 0)
        #expect(first.coordinates == [near, far])
        #expect(first.residentBytes == TerrainVolumeField.brickAllocationBytes * 2)
        let same = try first.preparing(field: TerrainVolumeField(document: document, base: source), required: [near, far])
        #expect(same.builtBrickCount == 0 && same.reusedBrickCount == 2)
        #expect(same.brickGeneration(at: near) == first.brickGeneration(at: near))
        #expect(same.brickGeneration(at: far) == first.brickGeneration(at: far))
    }

    @Test("Local sculpt and ordered operand changes leave a remote brick untouched")
    func localInvalidation() throws {
        let source = try base(), document = TerrainVolumeDocumentAsset(cellSize: 1)
        let empty = try TerrainVolumeCache(maximumBricks: 2)
        let first = try #require(try? empty.preparing(field: TerrainVolumeField(document: document, base: source), required: [near, far]))
        let oldNear = try #require(first.brick(at: near)), oldFar = try #require(first.brick(at: far))
        #expect(try source.setHeight(3, at: .init(x: 2, z: 2)))
        let sculpted = try first.preparing(field: TerrainVolumeField(document: document, base: source), required: [near, far])
        #expect(sculpted.builtBrickCount == 1 && sculpted.reusedBrickCount == 1)
        #expect(sculpted.brickGeneration(at: near) != first.brickGeneration(at: near))
        #expect(sculpted.brickGeneration(at: far) == first.brickGeneration(at: far))
        let index = (2 * 33 + 1) * 33 + 2
        #expect(oldNear.values[index] > 0)
        #expect(try #require(sculpted.brick(at: near)).values[index] < 0)
        #expect(try #require(sculpted.brick(at: far)).values == oldFar.values)
        let operation = TerrainVolumeOperation(operation: .union, operand: .primitive(.sphere(radius: 3)), transform: .init(translation: [16, 3, 16]), layerID: 7)
        let edited = try sculpted.preparing(field: TerrainVolumeField(document: .init(cellSize: 1, operations: [operation]), base: source), required: [near, far])
        #expect(edited.builtBrickCount == 1 && edited.reusedBrickCount == 1)
        #expect(edited.brickGeneration(at: far) == first.brickGeneration(at: far))
    }

    @Test("Changed prepared source generation invalidates only its relevant cached brick")
    func meshGeneration() throws {
        let source = try base()
        let operation = TerrainVolumeOperation(operation: .union, operand: .mesh(assetPath: "Models/solid.obj", scene: nil), transform: .init(translation: [8, 3, 8]))
        let points: [Vector3] = [[0, 0, 0], [6, 0, 0], [0, 6, 0], [0, 0, 6]], indices: [UInt32] = [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3]
        let document = TerrainVolumeDocumentAsset(cellSize: 1, operations: [operation])
        let firstMesh = try TerrainVolumePreparedMesh(operation: operation, positions: points, indices: indices)
        let firstField = try TerrainVolumeField(document: document, base: source, preparedMeshes: [firstMesh])
        let empty = try TerrainVolumeCache(maximumBricks: 2)
        let first = try #require(try? empty.preparing(field: firstField, required: [near, far]))
        let nextMesh = try TerrainVolumePreparedMesh(operation: operation, positions: points, indices: indices)
        let nextField = try TerrainVolumeField(document: document, base: source, preparedMeshes: [nextMesh])
        let next = try first.preparing(field: nextField, required: [near, far])
        #expect(next.builtBrickCount == 1 && next.reusedBrickCount == 1)
        #expect(next.brickGeneration(at: near) != first.brickGeneration(at: near))
        #expect(next.brickGeneration(at: far) == first.brickGeneration(at: far))
    }

    @Test("Residency forks preserve authored hidden page dependencies while draw coverage changes")
    func hiddenBaseCoverage() throws {
        let source = try base()
        #expect(try source.setHeight(5, at: .init(x: 258, z: 2)))
        let document = TerrainVolumeDocumentAsset(cellSize: 1), empty = try TerrainVolumeCache(maximumBricks: 2)
        let first = try #require(try? empty.preparing(field: TerrainVolumeField(document: document, base: source), required: [near, far]))
        let regions = try source.resourceCoordinates.map { try #require(try source.regionAsset(at: $0)) }
        let hidden = try source.residencySnapshot(regions: regions, visible: [.init(x: 0, z: 0)], expectedRevision: source.revision)
        let hiddenCache = try first.preparing(field: TerrainVolumeField(document: document, base: hidden), required: [near, far])
        #expect(hiddenCache.builtBrickCount == 0 && hiddenCache.reusedBrickCount == 2)
        #expect(hiddenCache.brickGeneration(at: far) == first.brickGeneration(at: far))
        let revealed = try hidden.residencySnapshot(regions: regions, visible: [.init(x: 0, z: 0), .init(x: 1, z: 0)], expectedRevision: hidden.revision)
        let restored = try hiddenCache.preparing(field: TerrainVolumeField(document: document, base: revealed), required: [near, far])
        #expect(restored.builtBrickCount == 0 && restored.reusedBrickCount == 2)
    }

    @Test("Eviction, pins and budget failures retain complete prior generations")
    func residencyAndFailure() throws {
        let source = try base(), field = try TerrainVolumeField(document: .init(cellSize: 1), base: source)
        let empty = try TerrainVolumeCache(maximumBytes: TerrainVolumeField.brickAllocationBytes * 2, maximumBricks: 2)
        let first = try #require(try? empty.preparing(field: field, required: [near, far]))
        let evicted = try first.preparing(field: field, required: [far])
        #expect(evicted.coordinates == [far] && evicted.evictedBrickCount == 1)
        let pinned = try first.preparing(field: field, required: [far], pinned: [near])
        #expect(pinned.coordinates == [near, far] && pinned.reusedBrickCount == 2)
        #expect(throws: TerrainVolumeFieldError.memoryBudgetExceeded) {
            try pinned.preparing(field: field, required: [.init(x: 16, y: 0, z: 0)], pinned: [near, far])
        }
        #expect(throws: TerrainVolumeFieldError.workBudgetExceeded) { try empty.preparing(field: field, required: [near, far], maximumWork: 40_000) }
        #expect(empty.coordinates.isEmpty && first.coordinates == [near, far])
        #expect(throws: TerrainVolumeFieldError.invalidCoordinate) { try first.preparing(field: field, required: [near, near]) }
    }
}
