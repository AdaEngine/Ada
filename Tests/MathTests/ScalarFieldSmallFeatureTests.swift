import Math
import Testing

@Suite("Representable scalar features near zero")
struct ScalarFieldSmallFeatureTests {
    @Test("Small negative samples retain their representable closed surface", arguments: [Float(1e-7), Float(1e-12)])
    func subcellSphere(radius: Float) throws {
        let solid = try ScalarSolid(primitive: .sphere(radius: radius))
        var values: [Float] = []
        for z in -1...1 {
            for y in -1...1 {
                for x in -1...1 { values.append(try solid.value(at: [Float(x), Float(y), Float(z)])) }
            }
        }
        let mesh = try ScalarFieldSurface.extract(ScalarFieldGrid(origin: [-1, -1, -1], spacing: 1, cellCount: [2, 2, 2], values: values))
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
            #expect(point.length > radius * 0.8 && point.length < radius * 1.2)
            #expect(mesh.normals[index].dot(point / radius) > 0)
        }
    }
}
