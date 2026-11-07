import AdaAssets
import AdaScene
import Foundation
import Math
import Testing

@Suite("Canonical terrain volume field kernel")
struct TerrainVolumeFieldTests {
    private func base() throws -> TerrainHeightStorage {
        try TerrainHeightStorage(importing: Terrain3D(resolution: 65, size: 64))
    }

    private func operations() -> [TerrainVolumeOperation] {
        [
            .init(
                operation: .subtract,
                operand: .primitive(.capsule(radius: 2, halfHeight: 20)),
                transform: .init(translation: [0, -3, 0], rotation: Quat(axis: .right, angle: .pi / 2), scale: .one)
            ),
            .init(operation: .union, operand: .primitive(.box(halfExtents: [5, 1, 3])), transform: .init(translation: [10, 3, 0]), layerID: 7)
        ]
    }

    @Test("Heightfield solid, subtracted tunnel, separated added ledge and material provenance coexist")
    func caveAndOverhang() throws {
        let document = TerrainVolumeDocumentAsset(cellSize: 1, origin: [-32, 0, -32], operations: operations())
        let field = try #require(try? TerrainVolumeField(document: document, base: base(), interiorLayerID: 12), "A valid volume field must prepare")
        #expect(try field.sample(at: [0, -3, 0]).value > 0)
        #expect(try field.sample(at: [20, -3, 0]).value < 0)
        #expect(try field.sample(at: [10, 3, 0]).value < 0)
        #expect(try field.sample(at: [10, 1.5, 0]).value > 0)
        #expect(try field.sample(at: [10, 3, 0]).materialTag == 7)
        #expect(try field.sample(at: [0, -3, 0]).materialTag == 12)
    }

    @Test("Ordered overlap and immutable base snapshots survive source sculpt and re-evaluation")
    func orderAndBaseSnapshot() throws {
        let storage = try base()
        let shape = TerrainVolumeOperand.primitive(.sphere(radius: 2))
        let add = TerrainVolumeOperation(operation: .union, operand: shape, transform: .init(translation: [0, 3, 0]))
        let cut = TerrainVolumeOperation(operation: .subtract, operand: shape, transform: add.transform)
        let field = try #require(try? TerrainVolumeField(document: .init(cellSize: 1, operations: [add, cut]), base: storage))
        #expect(try field.sample(at: [0, 3, 0]).value > 0)
        let reversed = try TerrainVolumeField(document: .init(cellSize: 1, operations: [cut, add]), base: storage)
        #expect(try reversed.sample(at: [0, 3, 0]).value < 0)
        #expect(try storage.setHeight(10, at: .init(x: 42, z: 42)))
        #expect(try field.sample(at: [10, 5, 10]).value > 0)
        let updated = try TerrainVolumeField(document: field.document, base: storage)
        #expect(try updated.sample(at: [10, 5, 10]).value < 0)
        #expect(try updated.sample(at: [0, 3, 0]).value > 0)
    }

    @Test("Adjacent signed bricks contain identical canonical border values and material tags")
    func sharedBrickSamples() throws {
        let field = try #require(try? TerrainVolumeField(document: .init(cellSize: 1, origin: [-32, 0, -32], operations: operations()), base: base(), interiorLayerID: 12))
        let left = try field.makeBrick(x: 0, y: -1, z: 0), right = try field.makeBrick(x: 1, y: -1, z: 0)
        for z in 0...32 {
            for y in 0...32 {
                let a = (z * 33 + y) * 33 + 32, b = (z * 33 + y) * 33
                #expect(left.values[a].bitPattern == right.values[b].bitPattern)
                #expect(left.materialTags[a] == right.materialTags[b])
            }
        }
        #expect(!(try field.surface(of: left)).indices.isEmpty)
        #expect(!(try field.surface(of: right)).indices.isEmpty)
    }

    @Test("Prepared closed mesh placement is checked against operation metadata")
    func preparedMesh() throws {
        let points: [Vector3] = [[0, 0, 0], [2, 0, 0], [0, 2, 0], [0, 0, 2]]
        let indices: [UInt32] = [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3]
        let operation = TerrainVolumeOperation(operation: .union, operand: .mesh(assetPath: "Models/cave.obj", scene: nil), transform: .init(translation: [8, 2, 8]), layerID: 9)
        let prepared = try TerrainVolumePreparedMesh(operation: operation, positions: points, indices: indices)
        let field = try #require(try? TerrainVolumeField(document: .init(cellSize: 1, operations: [operation]), base: base(), preparedMeshes: [prepared]))
        #expect(try field.sample(at: [8.25, 2.25, 8.25]).value < 0)
        #expect(try field.sample(at: [8.25, 2.25, 8.25]).materialTag == 9)
        #expect(throws: TerrainVolumeFieldError.missingMesh) {
            try TerrainVolumeField(document: field.document, base: base())
        }
        let changed = TerrainVolumeOperation(id: operation.id, operation: .union, operand: operation.operand, transform: .init(translation: [9, 2, 8]))
        #expect(throws: TerrainVolumeFieldError.mismatchedMesh) {
            try TerrainVolumeField(document: .init(cellSize: 1, operations: [changed]), base: base(), preparedMeshes: [prepared])
        }
    }

    @Test("Invalid addresses and memory/work limits reject before returning a partial brick")
    func budgets() throws {
        let field = try #require(try? TerrainVolumeField(document: .init(cellSize: 1), base: base()))
        #expect(throws: TerrainVolumeFieldError.memoryBudgetExceeded) { try field.makeBrick(x: 0, y: 0, z: 0, maximumBytes: 0) }
        #expect(throws: TerrainVolumeFieldError.workBudgetExceeded) { try field.makeBrick(x: 0, y: 0, z: 0, maximumWork: 0) }
        #expect(throws: TerrainVolumeFieldError.invalidCoordinate) { try field.makeBrick(x: .max, y: 0, z: 0) }
        #expect(throws: TerrainVolumeFieldError.invalidCoordinate) { try field.sample(at: [.nan, 0, 0]) }
        #expect(throws: TerrainVolumeFieldError.workBudgetExceeded) { try field.sample(at: [0, 0, 0], maximumWork: 0) }
    }
}
