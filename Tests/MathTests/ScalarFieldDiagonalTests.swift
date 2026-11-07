import Math
import Testing

@Suite("Scalar tetrahedral orientation compatibility")
struct ScalarFieldDiagonalTests {
    private func grid(offset: SIMD3<Int32>, origin: Vector3, spacing: Float, center: Vector3) throws -> ScalarFieldGrid {
        var values: [Float] = []
        for z in 0...16 {
            for y in 0...16 {
                for x in 0...16 {
                    let point = Vector3(
                        origin.x + Float(Int64(offset.x) + Int64(x)) * spacing,
                        origin.y + Float(Int64(offset.y) + Int64(y)) * spacing,
                        origin.z + Float(Int64(offset.z) + Int64(z)) * spacing
                    )
                    let delta = point - center
                    values.append(delta.dot(delta) - 5.3 * 5.3 * spacing * spacing)
                }
            }
        }
        return try .init(origin: origin, spacing: spacing, cellCount: [16, 16, 16], values: values, cellOffset: offset)
    }

    @Test("Both tetrahedral orientations retain closed outward sphere geometry", arguments: [ScalarFieldSurfaceDiagonal.risingXZ, .fallingXZ])
    func closedSphere(diagonal: ScalarFieldSurfaceDiagonal) throws {
        let center = Vector3(8.13, 8.27, 8.41)
        let mesh = try ScalarFieldSurface.extract(grid(offset: .zero, origin: .zero, spacing: 1, center: center), diagonal: diagonal)
        try #require(!mesh.indices.isEmpty)
        var edges: [UInt64: Int] = [:]
        for index in stride(from: 0, to: mesh.indices.count, by: 3) {
            for corner in 0..<3 {
                let a = mesh.indices[index + corner], b = mesh.indices[index + (corner + 1) % 3]
                edges[(UInt64(min(a, b)) << 32) | UInt64(max(a, b)), default: 0] += 1
            }
        }
        #expect(edges.values.allSatisfy { $0 == 2 })
        for (index, point) in mesh.positions.enumerated() {
            #expect(abs((point - center).length - 5.3) < 0.15)
            #expect(abs(mesh.normals[index].length - 1) < 0.001)
            #expect(mesh.normals[index].dot(point - center) > 4.5)
        }
    }

    @Test("Both orientations match shared fractional signed lattice boundaries", arguments: [ScalarFieldSurfaceDiagonal.risingXZ, .fallingXZ])
    func sharedBoundary(diagonal: ScalarFieldSurfaceDiagonal) throws {
        let origin = Vector3(0.17, 0.11, -0.23), center = Vector3(0.23, 0.19, -0.13)
        let left = try ScalarFieldSurface.extract(grid(offset: [-16, -8, -8], origin: origin, spacing: 0.3, center: center), diagonal: diagonal)
        let right = try ScalarFieldSurface.extract(grid(offset: [0, -8, -8], origin: origin, spacing: 0.3, center: center), diagonal: diagonal)
        let first = Set(left.positions.filter { $0.x == origin.x }), second = Set(right.positions.filter { $0.x == origin.x })
        #expect(first.count > 8)
        #expect(first == second)
    }
}
