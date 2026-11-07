import Math
import Testing

@Suite("Imported solid extraction and cancellation")
struct ScalarMeshExtractionTests {
    private func fixture() -> (positions: [Vector3], indices: [UInt32]) {
        let outline: [Vector2] = [[0, 0], [3, 0], [3, 1], [1, 1], [1, 3], [0, 3]]
        let positions = [-8.0, 8.0].flatMap { y in outline.map { Vector3($0.x, Float(y), $0.y) } }
        var indices: [UInt32] = []
        for index in 1..<5 { indices += [0, UInt32(index), UInt32(index + 1), 6, UInt32(index + 7), UInt32(index + 6)] }
        for index in 0..<6 {
            let a = UInt32(index), b = UInt32((index + 1) % 6)
            indices += [a, b + 6, b, a, a + 6, b + 6]
        }
        return (positions, indices)
    }

    @Test("Concave mesh subtraction produces a closed surface with an L-shaped open shaft")
    func concaveSubtraction() throws {
        let source = fixture(), cut = try ScalarMeshSolid(positions: source.positions, indices: source.indices)
        let base = try ScalarSolid(primitive: .box(halfExtents: [4, 3, 4]))
        var values: [Float] = []
        for z in 0...20 {
            for y in 0...16 {
                for x in 0...20 {
                    let point = Vector3(Float(x) * 0.5 - 5, Float(y) * 0.5 - 4, Float(z) * 0.5 - 5)
                    values.append(try ScalarBooleanOperation.subtract.apply(base: base.value(at: point), operand: cut.value(at: point)))
                }
            }
        }
        let mesh = try ScalarFieldSurface.extract(ScalarFieldGrid(origin: [-5, -4, -5], spacing: 0.5, cellCount: [20, 16, 20], values: values))
        try #require(!mesh.indices.isEmpty)
        var edges: [UInt64: Int] = [:]
        for index in stride(from: 0, to: mesh.indices.count, by: 3) {
            for corner in 0..<3 {
                let a = mesh.indices[index + corner], b = mesh.indices[index + (corner + 1) % 3]
                edges[(UInt64(min(a, b)) << 32) | UInt64(max(a, b)), default: 0] += 1
            }
        }
        #expect(edges.values.allSatisfy { $0 == 2 })
        #expect(try cut.value(at: [0.5, 0, 2]) < 0)
        #expect(try cut.value(at: [2, 0, 2]) > 0)
        #expect(mesh.positions.contains { abs($0.x - 1) < 0.01 && $0.z > 1.5 && abs($0.y) < 2 })
    }

    @Test("Cancelled validation and sampling throw before returning partial results")
    func cancellation() async throws {
        let source = fixture(), solid = try ScalarMeshSolid(positions: source.positions, indices: source.indices), gate = MeshSolidGate()
        let validation = Task {
            await gate.wait()
            return try ScalarMeshSolid(positions: source.positions, indices: source.indices)
        }
        validation.cancel(); await gate.open()
        await #expect(throws: CancellationError.self) { try await validation.value }
        let samplingGate = MeshSolidGate()
        let sampling = Task {
            await samplingGate.wait()
            return try solid.value(at: [0.5, 0, 2])
        }
        sampling.cancel(); await samplingGate.open()
        await #expect(throws: CancellationError.self) { try await sampling.value }
    }

    @Test("Full-width untrusted indices and unused nonfinite vertices are rejected")
    func untrustedPayload() throws {
        let source = fixture()
        var indices = source.indices
        indices[0] = .max
        #expect(throws: ScalarMeshSolidError.invalidMesh) { try ScalarMeshSolid(positions: source.positions, indices: indices) }
        #expect(throws: ScalarMeshSolidError.invalidMesh) {
            try ScalarMeshSolid(positions: source.positions + [Vector3(.nan, 0, 0)], indices: source.indices)
        }
    }
}

private actor MeshSolidGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !opened else {
            return
        }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() { opened = true; continuation?.resume(); continuation = nil }
}
