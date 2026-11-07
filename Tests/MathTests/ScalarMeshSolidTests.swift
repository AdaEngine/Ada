import Math
import Testing

@Suite("Validated concave mesh solid operands")
struct ScalarMeshSolidTests {
    private func prism() -> (positions: [Vector3], indices: [UInt32]) {
        let outline: [Vector2] = [[0, 0], [3, 0], [3, 1], [1, 1], [1, 3], [0, 3]]
        let positions = [-1.0, 1.0].flatMap { y in outline.map { Vector3($0.x, Float(y), $0.y) } }
        var indices: [UInt32] = []
        for index in 1..<5 {
            indices += [0, UInt32(index), UInt32(index + 1), 6, UInt32(index + 7), UInt32(index + 6)]
        }
        for index in 0..<6 {
            let a = UInt32(index), b = UInt32((index + 1) % 6)
            indices += [a, b + 6, b, a, a + 6, b + 6]
        }
        return (positions, indices)
    }

    @Test("Concave membership and nearest distance follow the actual closed surface", arguments: [false, true])
    func concaveSamples(reflected: Bool) throws {
        let source = prism()
        var matrix = Transform3D(translation: [4, 2, -5], rotation: .identity, scale: [reflected ? -2 : 2, 1.5, 0.5])
        matrix.y += matrix.x * 0.25
        let solid = try ScalarMeshSolid(positions: source.positions, indices: source.indices, transform: matrix)
        func sample(_ local: Vector3) throws -> Float { try solid.value(at: (matrix * Vector4(local, 1)).xyz) }
        #expect(try sample([0.5, 0, 2]) < 0)
        #expect(try sample([2, 0, 0.5]) < 0)
        #expect(try sample([2, 0, 2]) > 0)
        #expect(try sample([0.5, 2, 0.5]) > 0)
        #expect(abs(try sample([0, 0, 1])) < 0.00001)
        let identity = try ScalarMeshSolid(positions: source.positions, indices: source.indices)
        #expect(abs(try identity.value(at: [0.5, 0, 2]) + 0.5) < 0.00001)
        #expect(abs(try identity.value(at: [2, 0, 2]) - 1) < 0.00001)
    }

    @Test("Exact duplicate attribute seam vertices weld before closure validation")
    func attributeSeams() throws {
        let source = prism()
        let positions = source.indices.map { source.positions[Int($0)] }
        let solid = try ScalarMeshSolid(positions: positions, indices: positions.indices.map(UInt32.init))
        #expect(try solid.value(at: [0.5, 0, 2]) < 0)
    }

    @Test("Open, nonmanifold, inconsistently wound and invalid triangles fail explicitly")
    func rejectsInvalidTopology() throws {
        let source = prism()
        #expect(throws: ScalarMeshSolidError.openOrNonManifold) {
            try ScalarMeshSolid(positions: source.positions, indices: Array(source.indices.dropLast(3)))
        }
        #expect(throws: ScalarMeshSolidError.openOrNonManifold) {
            try ScalarMeshSolid(positions: source.positions, indices: source.indices + source.indices.prefix(3))
        }
        var reversed = source.indices
        reversed.swapAt(1, 2)
        #expect(throws: ScalarMeshSolidError.inconsistentWinding) { try ScalarMeshSolid(positions: source.positions, indices: reversed) }
        #expect(throws: ScalarMeshSolidError.invalidMesh) { try ScalarMeshSolid(positions: source.positions, indices: [0, 0, 1]) }
        #expect(throws: ScalarMeshSolidError.invalidMesh) { try ScalarMeshSolid(positions: source.positions, indices: [0, 1, 999]) }
        #expect(throws: ScalarMeshSolidError.invalidMesh) { try ScalarMeshSolid(positions: [[.nan, 0, 0]], indices: [0, 0, 0]) }
        #expect(throws: ScalarSolidError.invalidTransform) {
            try ScalarMeshSolid(positions: source.positions, indices: source.indices, transform: .init(scale: [1, 0, 1]))
        }
    }

    @Test("Intersecting closed components are rejected before sampling")
    func rejectsIntersectingComponents() throws {
        let source = prism()
        let positions = source.positions + source.positions.map { $0 + Vector3(0.5, 0.5, 0.5) }
        let indices = source.indices + source.indices.map { $0 + UInt32(source.positions.count) }
        #expect(throws: ScalarMeshSolidError.selfIntersection) { try ScalarMeshSolid(positions: positions, indices: indices) }
    }

    @Test("Validation and query budgets fail without silently accepting an incomplete solid")
    func workLimits() throws {
        let source = prism()
        #expect(throws: ScalarMeshSolidError.invalidMesh) {
            try ScalarMeshSolid(positions: source.positions, indices: source.indices, maximumTriangles: 4)
        }
        #expect(throws: ScalarMeshSolidError.workBudgetExceeded) {
            try ScalarMeshSolid(positions: source.positions, indices: source.indices, maximumValidationWork: 0)
        }
        let solid = try ScalarMeshSolid(positions: source.positions, indices: source.indices)
        #expect(throws: ScalarMeshSolidError.workBudgetExceeded) { try solid.value(at: [0.5, 0, 2], maximumWork: 0) }
        #expect(throws: ScalarMeshSolidError.invalidPoint) { try solid.value(at: [.infinity, 0, 0]) }
    }
}
