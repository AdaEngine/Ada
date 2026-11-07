import AdaGeometry
import Foundation
import Math
import Testing

@Suite("Retained mesh terrain evaluation")
struct MeshTerrainEvaluatorTests {
    @Test("A join outside the finite terrain footprint retains the last valid surface",
          .enabled(if: TriangleMeshBoolean.isAvailable), arguments: [Float(6.25), 10])
    func outsideJoinRetainsAcceptedSurface(offset: Float) async throws {
        let base = MeshTerrainBaseSection(surface: try TriangleSurface.ground(size: [12, 8], cells: 6), closure: .ground(bottomHeight: -8))
        let operand = try TriangleSurface.box(minimum: [-1, -1, -1], maximum: [1, 2, 1])
        var document = MeshTerrainDocument(sections: [base], modifiers: [.init(sourceID: 1, operation: .union, surface: operand)])
        let evaluator = MeshTerrainEvaluator()
        let accepted = try await evaluator.evaluate(document)
        document.modifiers[0].transform = .init(translation: [offset, 0, 0])
        let requested = document
        await #expect(throws: TriangleGeometryError.operandOutsideTerrain) { try await evaluator.evaluate(requested) }
        let retained = await evaluator.lastAccepted
        #expect(retained?.patches.first?.generation == accepted.patches.first?.generation)
        #expect(try retained?.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.hit.position.y == 2)
    }

    @Test("Opt-in contact rounding stays within deviation and preserves the shared section boundary", .enabled(if: TriangleMeshBoolean.isAvailable))
    func roundingPreservesClosedJoinLimits() async throws {
        var input = try document()
        input.modifiers[0].transform = .identity
        let evaluator = MeshTerrainEvaluator()
        let sharp = try await evaluator.evaluate(input)
        input.modifiers[0].rounding = .init(radius: 2, maximumDeviation: 0.15)
        let rounded = try await evaluator.evaluate(input)
        #expect(rounded.patches.count == sharp.patches.count)
        var anyDisplacement = false, checkedBoundary = false
        for (before, after) in zip(sharp.patches, rounded.patches) {
            #expect(after.surface.indices == before.surface.indices)
            #expect(after.surface.faceSources == before.surface.faceSources)
            #expect(after.surface.faceIDs == before.surface.faceIDs)
            #expect(after.surface.textureCoordinates == before.surface.textureCoordinates)
            for (old, new) in zip(before.surface.positions, after.surface.positions) {
                let displacement = (new - old).length
                #expect(displacement <= 0.1501)
                if displacement > 0.0001 { anyDisplacement = true }
                if old.x == 0 {
                    checkedBoundary = true
                    #expect(old == new)
                }
            }
        }
        #expect(checkedBoundary)
        #expect(anyDisplacement)
        #expect(try rounded.raycast(.init(origin: [-6, 5, 0], direction: [0, -1, 0]))?.hit.position.y == 0)
    }

    @Test("A gizmo-sized floating translation produces a valid joined query surface", .enabled(if: TriangleMeshBoolean.isAvailable))
    func fractionalGizmoTranslation() async throws {
        let document = MeshTerrainDocument(sections: [
            .init(surface: try TriangleSurface.ground(size: [128, 128], cells: 64), closure: .ground(bottomHeight: -32))
        ], modifiers: [.init(sourceID: 1, operation: .union,
            surface: try TriangleSurface.box(minimum: [-1, -1, -1], maximum: [1, 1, 1]),
            transform: .init(translation: [3.000001, 0, 0]))])
        await #expect(throws: Never.self) {
            let snapshot = try await MeshTerrainEvaluator().evaluate(document)
            #expect(try snapshot.raycast(.init(origin: [3, 5, 0], direction: [0, -1, 0]))?.hit.position.y == 1)
            #expect(try snapshot.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.hit.position.y == 0)
        }
    }

    private func document() throws -> MeshTerrainDocument {
        let left = try TriangleSurface.ground(size: [8, 8], cells: 4).transformed(by: .init(translation: [-4, 0, 0]))
        let right = try TriangleSurface.ground(size: [8, 8], cells: 4).transformed(by: .init(translation: [4, 0, 0]))
        let root = try TriangleSurface.box(minimum: [-1, -1, -1], maximum: [1, 2, 1])
        return .init(sections: [.init(surface: left, closure: .ground(bottomHeight: -8)), .init(surface: right, closure: .ground(bottomHeight: -8))],
                     modifiers: [.init(sourceID: 7, operation: .union, surface: root, transform: .init(translation: [-4, 0, 0]))])
    }

    @Test("Moving a retained source restores its old ground and reuses unrelated accepted patches", .enabled(if: TriangleMeshBoolean.isAvailable))
    func moveAndRestore() async throws {
        var document = try document()
        let evaluator = MeshTerrainEvaluator()
        let original = try await evaluator.evaluate(document)
        #expect(original.rebuiltPatchCount == 2)
        let stable = try await evaluator.evaluate(document)
        #expect(stable.reusedPatchCount == 2)
        document.modifiers[0].transform = .init(translation: [-2, 0, 0])
        let moved = try await evaluator.evaluate(document)
        #expect(moved.rebuiltPatchCount == 1)
        #expect(moved.patches[1].generation == original.patches[1].generation)
        let oldHit = try #require(try moved.raycast(.init(origin: [-4, 6, 0], direction: [0, -1, 0])))
        let newHit = try #require(try moved.raycast(.init(origin: [-2, 6, 0], direction: [0, -1, 0])))
        #expect(abs(oldHit.hit.position.y) < 0.001)
        #expect(abs(newHit.hit.position.y - 2) < 0.001)
        document.modifiers.removeAll()
        let removed = try await evaluator.evaluate(document)
        #expect(removed.patches[1].generation == original.patches[1].generation)
        let restored = try #require(try removed.raycast(.init(origin: [-2, 6, 0], direction: [0, -1, 0])))
        #expect(abs(restored.hit.position.y) < 0.001)
    }

    @Test("An operand crossing sections has one compatible visible seam and no closure faces", .enabled(if: TriangleMeshBoolean.isAvailable))
    func sectionSeam() async throws {
        var document = try document()
        document.modifiers[0].transform = .identity
        let snapshot = try await MeshTerrainEvaluator().evaluate(document)
        func boundary(_ surface: TriangleSurface) -> Set<Vector3> {
            Set(surface.indices.map { surface.positions[Int($0)] }.filter { $0.x == 0 })
        }
        #expect(boundary(snapshot.patches[0].surface) == boundary(snapshot.patches[1].surface))
        #expect(!snapshot.patches[0].surface.faceSources.contains(TrianglePatchClosure.closureSource))
        #expect(!snapshot.patches[1].surface.faceSources.contains(TrianglePatchClosure.closureSource))
    }

    @Test("Malformed updates retain the last accepted generation", .enabled(if: TriangleMeshBoolean.isAvailable))
    func retainOnError() async throws {
        var document = try document()
        let evaluator = MeshTerrainEvaluator()
        let original = try await evaluator.evaluate(document)
        document.modifiers[0].surface = TriangleSurface(positions: document.modifiers[0].surface.positions, indices: [0, 1, 2])
        await #expect(throws: TriangleGeometryError.nonManifold) { try await evaluator.evaluate(document) }
        let retained = await evaluator.lastAccepted
        #expect(retained?.patches.map(\.generation) == original.patches.map(\.generation))
    }

    @Test("Float output of an offset reflected join remains a valid query and collision surface", .enabled(if: TriangleMeshBoolean.isAvailable))
    func offsetReflectedJoin() async throws {
        let ground = try TriangleSurface.ground(size: [12, 8], cells: 6)
        let source = try TriangleSurface.box(minimum: [-1, -1, -1], maximum: [1, 2, 1])
        let document = MeshTerrainDocument(sections: [.init(surface: ground, closure: .ground(bottomHeight: -4))], modifiers: [
            .init(sourceID: 7, operation: .union, surface: source,
                  transform: .init(translation: [3, 0.25, 0], rotation: .identity, scale: [-1, 1, 1]))
        ])
        await #expect(throws: Never.self) {
            let snapshot = try await MeshTerrainEvaluator().evaluate(document)
            let hit = try snapshot.raycast(.init(origin: [3, 5, 0], direction: [0, -1, 0]))
            #expect(hit?.hit.position.y == 2.25)
            #expect(snapshot.patches[0].surface.faceSources.contains(7))
        }
    }

    @Test("Canonical document roundtrip retains source identity, order and placement")
    func roundtrip() throws {
        let original = try document()
        let data = try original.canonicalData()
        let restored = try JSONDecoder().decode(MeshTerrainDocument.self, from: data)
        #expect(restored == original)
        #expect(try restored.canonicalData() == data)
    }
}
