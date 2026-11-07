import Math
import Testing

@Suite("Scalar field surface extraction")
struct ScalarFieldSurfaceTests {
    private func sphere(origin: Vector3, center: Vector3, radius: Float) throws -> ScalarFieldGrid {
        var values: [Float] = []
        for z in 0...32 {
            for y in 0...32 {
                for x in 0...32 {
                    let point = origin + Vector3(Float(x), Float(y), Float(z)) - center
                    values.append(point.dot(point) - radius * radius)
                }
            }
        }
        return try ScalarFieldGrid(origin: origin, spacing: 1, cellCount: [32, 32, 32], values: values)
    }

    @Test("A negative-inside smooth sphere extracts a closed indexed outward surface")
    func closedSphere() throws {
        let center = Vector3(0.37, 0.21, -0.13), radius: Float = 5.7
        let grid = try sphere(origin: [-16, -16, -16], center: center, radius: radius)
        let mesh = try ScalarFieldSurface.extract(grid)
        try #require(!mesh.indices.isEmpty && mesh.indices.count.isMultiple(of: 3))
        try #require(mesh.normals.count == mesh.positions.count)
        try #require(mesh.indices.allSatisfy { Int($0) < mesh.positions.count })
        var edges: [UInt64: Int] = [:]
        for index in stride(from: 0, to: mesh.indices.count, by: 3) {
            let triangle = [mesh.indices[index], mesh.indices[index + 1], mesh.indices[index + 2]]
            let a = mesh.positions[Int(triangle[0])], b = mesh.positions[Int(triangle[1])], c = mesh.positions[Int(triangle[2])]
            let normal = (b - a).cross(c - a)
            #expect(normal.dot((a + b + c) / 3 - center) > 0)
            for edge in 0..<3 {
                let first = triangle[edge], second = triangle[(edge + 1) % 3]
                let key = (UInt64(min(first, second)) << 32) | UInt64(max(first, second))
                edges[key, default: 0] += 1
            }
        }
        #expect(edges.values.allSatisfy { $0 == 2 })
        for (index, point) in mesh.positions.enumerated() {
            let relative = point - center
            #expect(abs(relative.length - radius) < 0.12)
            #expect(abs(mesh.normals[index].length - 1) < 0.001)
            #expect(mesh.normals[index].dot(relative) > radius * 0.95)
        }
    }

    @Test("Adjacent 32-cell grids share the exact same canonical seam vertices")
    func sharedBrickBoundary() throws {
        let center = Vector3(32, 16.2, 16.4)
        let left = try ScalarFieldSurface.extract(sphere(origin: [0, 0, 0], center: center, radius: 10.3))
        let right = try ScalarFieldSurface.extract(sphere(origin: [32, 0, 0], center: center, radius: 10.3))
        func boundary(_ points: [Vector3]) -> Set<UInt64> {
            Set(points.filter { $0.x == 32 }.map { (UInt64($0.y.bitPattern) << 32) | UInt64($0.z.bitPattern) })
        }
        let leftBoundary = boundary(left.positions)
        #expect(leftBoundary.count > 12)
        #expect(leftBoundary == boundary(right.positions))
    }

    @Test("Malformed grids and insufficient output budgets are rejected")
    func boundedExtraction() throws {
        #expect(throws: ScalarFieldSurfaceError.invalidGrid) {
            try ScalarFieldGrid(origin: .zero, spacing: 1, cellCount: [33, 1, 1], values: [])
        }
        #expect(throws: ScalarFieldSurfaceError.invalidGrid) {
            try ScalarFieldGrid(origin: .zero, spacing: .infinity, cellCount: [1, 1, 1], values: Array(repeating: 1, count: 8))
        }
        #expect(throws: ScalarFieldSurfaceError.invalidGrid) {
            try ScalarFieldGrid(origin: .zero, spacing: 1, cellCount: [1, 1, 1], values: Array(repeating: .nan, count: 8))
        }
        let grid = try sphere(origin: [-16, -16, -16], center: .zero, radius: 5.7)
        #expect(throws: ScalarFieldSurfaceError.outputBudgetExceeded) {
            try ScalarFieldSurface.extract(grid, maximumTriangles: 1)
        }
    }
}
