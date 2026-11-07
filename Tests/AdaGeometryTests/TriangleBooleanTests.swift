import AdaGeometry
import Math
import Testing

@Suite("Mesh terrain triangle Boolean kernel", .enabled(if: TriangleMeshBoolean.isAvailable))
struct TriangleBooleanTests {
    static func box(center: Vector3 = .zero, size: Vector3 = .one, source: UInt32 = 0) -> TriangleSurface {
        let positions: [Vector3] = [[-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1],
                                    [-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1]]
        let indices: [UInt32] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4,
                                  3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5]
        return TriangleSurface(positions: positions.map { center + $0 * size * 0.5 }, indices: indices,
                               faceSources: Array(repeating: source, count: 12), faceIDs: Array(0..<12))
    }

    @Test("Overlapping solids fuse to a manifold surface rather than concatenated interior triangles")
    func joinedSurface() throws {
        let result = try TriangleMeshBoolean.apply(.union, base: Self.box(size: [4, 2, 4]),
                                                   operand: Self.box(center: [0.3, 1, 0.2], size: [1, 3, 1], source: 7))
        try #require(!result.indices.isEmpty)
        _ = try ScalarMeshSolid(positions: result.positions, indices: result.indices)
        #expect(Set(result.faceSources) == [0, 7])
        let solid = try ScalarMeshSolid(positions: result.positions, indices: result.indices)
        #expect(try solid.value(at: [0.3, 2, 0.2]) < 0)
        #expect(try solid.value(at: [1.5, 2, 0]) > 0)
    }

    @Test("Subtraction creates a real tunnel and retains coherent closed topology")
    func tunnel() throws {
        let result = try TriangleMeshBoolean.apply(.subtract, base: Self.box(size: [8, 4, 8]),
                                                   operand: Self.box(center: [0, -0.5, 0], size: [2, 2, 10], source: 9))
        let solid = try ScalarMeshSolid(positions: result.positions, indices: result.indices)
        #expect(try solid.value(at: [0, -0.5, 0]) > 0)
        #expect(try solid.value(at: [3, -0.5, 0]) < 0)
    }

    @Test("An open operand fails without mutating either input")
    func invalidOperand() throws {
        let base = Self.box()
        let open = TriangleSurface(positions: [[0, 0, 0], [1, 0, 0], [0, 0, 1]], indices: [0, 1, 2])
        #expect(throws: TriangleGeometryError.nonManifold) { try TriangleMeshBoolean.apply(.union, base: base, operand: open) }
        #expect(base == Self.box())
    }

    @Test("Open ground closes explicitly, unions visible root geometry and strips every temporary cap")
    func openGround() throws {
        let ground = TriangleSurface(positions: [[-4, 0, -4], [-4, 0, 4], [4, 0, -4], [4, 0, 4]], indices: [0, 1, 2, 1, 3, 2])
        let closed = try TrianglePatchClosure.closeGround(ground, below: -8)
        _ = try ScalarMeshSolid(positions: closed.positions, indices: closed.indices)
        let joined = try TriangleMeshBoolean.apply(.union, base: closed, operand: Self.box(center: [0.2, 0.5, 0.1], size: [2, 2, 2], source: 7))
        let visible = try TrianglePatchClosure.visibleSurface(joined)
        #expect(!visible.faceSources.contains(TrianglePatchClosure.closureSource))
        #expect(visible.indices.allSatisfy { visible.positions[Int($0)].y >= 0 })
        #expect(visible.faceSources.contains(7))
        #expect(visible.indices.contains { visible.positions[Int($0)].y > 1 })
    }

    @Test("Split UV attributes survive intersection and source provenance remains categorical")
    func attributes() throws {
        var operand = Self.box(center: [0.25, 0.7, 0.1], size: [2, 2, 2], source: 19)
        operand.textureCoordinates = operand.positions.map { [($0.x + 10) * 3, ($0.z + 10) * 5] }
        let result = try TriangleMeshBoolean.apply(.union, base: Self.box(size: [5, 1, 5]), operand: operand)
        for face in result.faceSources.indices where result.faceSources[face] == 19 {
            for index in result.indices[(face * 3)..<(face * 3 + 3)] {
                let point = result.positions[Int(index)], uv = result.textureCoordinates[Int(index)]
                #expect(abs(uv.x - (point.x + 10) * 3) < 0.0001)
                #expect(abs(uv.y - (point.z + 10) * 5) < 0.0001)
            }
        }
    }

    @Test("Mirrored nonuniform source transforms preserve outward topology")
    func reflected() throws {
        let operand = try Self.box(source: 3).transformed(by: .init(translation: [0.5, 0.75, 0], rotation: .identity, scale: [-2, 3, 1]))
        let result = try TriangleMeshBoolean.apply(.union, base: Self.box(size: [4, 1, 4]), operand: operand)
        _ = try ScalarMeshSolid(positions: result.positions, indices: result.indices)
        #expect(Set(result.faceSources) == [0, 3])
    }

    @Test("Declared budget failure is explicit and preserves inputs")
    func budget() throws {
        let base = Self.box()
        #expect(throws: TriangleGeometryError.budgetExceeded) {
            try TriangleMeshBoolean.apply(.union, base: base, operand: base, budget: .init(maximumBytes: 1))
        }
        #expect(base == Self.box())
    }

    @Test("A completely removed surface can receive a later union")
    func emptyThenUnion() throws {
        let empty = try TriangleMeshBoolean.apply(.subtract, base: Self.box(), operand: Self.box(size: [4, 4, 4], source: 2))
        #expect(empty.indices.isEmpty)
        let restored = try #require(try? TriangleMeshBoolean.apply(.union, base: empty, operand: Self.box(source: 4)), "Union with an empty evaluated base must succeed")
        #expect(!restored.indices.isEmpty)
        #expect(restored.faceSources.allSatisfy { $0 == 4 })
    }
}
