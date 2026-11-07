import Math
import Testing

@Suite("Canonical scalar lattice")
struct ScalarFieldLatticeTests {
    @Test("Signed integer brick offsets retain exact shared vertices at fractional lattice scale", arguments: [0, 1, 2])
    func fractionalLatticeSeams(axis: Int) throws {
        let origin = Vector3(-7.1, 2.3, -13.7), spacing: Float = 0.2
        let firstOffset = SIMD3<Int32>(-96, 64, -32)
        var secondOffset = firstOffset
        secondOffset[axis] += 32
        var center = SIMD3<Float>(Float(firstOffset.x) + 16.2, Float(firstOffset.y) + 16.4, Float(firstOffset.z) + 16.1)
        center[axis] = Float(secondOffset[axis])
        func field(_ offset: SIMD3<Int32>) throws -> ScalarFieldGrid {
            var values: [Float] = []
            for z in 0...32 {
                for y in 0...32 {
                    for x in 0...32 {
                        let point = SIMD3<Float>(Float(offset.x) + Float(x), Float(offset.y) + Float(y), Float(offset.z) + Float(z)) - center
                        values.append(point.x * point.x + point.y * point.y + point.z * point.z - 10.3 * 10.3)
                    }
                }
            }
            return try ScalarFieldGrid(origin: origin, spacing: spacing, cellCount: [32, 32, 32], values: values, cellOffset: offset)
        }
        let left = try ScalarFieldSurface.extract(field(firstOffset)), right = try ScalarFieldSurface.extract(field(secondOffset))
        let origins = SIMD3<Float>(origin.x, origin.y, origin.z)
        let plane = origins[axis] + Float(secondOffset[axis]) * spacing
        func boundary(_ positions: [Vector3]) -> Set<UInt64> {
            var result: Set<UInt64> = []
            for position in positions {
                let point = SIMD3<Float>(position.x, position.y, position.z)
                if point[axis] == plane {
                    result.insert((UInt64(point[(axis + 1) % 3].bitPattern) << 32) | UInt64(point[(axis + 2) % 3].bitPattern))
                }
            }
            return result
        }
        let seam = boundary(left.positions)
        #expect(seam.count > 12)
        #expect(seam == boundary(right.positions))
    }

    @Test("Coordinate precision is validated at the addressed lattice cells")
    func addressedCoordinatePrecision() throws {
        #expect(throws: ScalarFieldSurfaceError.invalidGrid) {
            try ScalarFieldGrid(origin: .zero, spacing: 1, cellCount: [1, 1, 1], values: Array(repeating: 1, count: 8), cellOffset: [.max, 0, 0])
        }
        #expect(throws: ScalarFieldSurfaceError.invalidGrid) {
            try ScalarFieldGrid(origin: [100_000_000, 0, 0], spacing: 5, cellCount: [32, 1, 1], values: Array(repeating: 1, count: 33 * 2 * 2))
        }
    }
}
