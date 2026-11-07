import Math
import Testing

@Suite("Independent scalar coordinate precision")
struct ScalarFieldThinPlateTests {
    @Test("Large horizontal coordinates retain a thin independently representable vertical extent")
    func thinPlate() throws {
        let solid = try ScalarSolid(primitive: .box(halfExtents: [8, 1e-7, 8]), transform: .init(translation: [16, 0, 16]))
        var values: [Float] = []
        for z in 0...32 {
            for y in -1...1 {
                for x in 0...32 { values.append(try solid.value(at: [Float(x), Float(y), Float(z)])) }
            }
        }
        let mesh = try ScalarFieldSurface.extract(ScalarFieldGrid(origin: [0, -1, 0], spacing: 1, cellCount: [32, 2, 32], values: values))
        try #require(!mesh.indices.isEmpty)
        #expect(mesh.positions.contains { $0.y > 0.9e-7 })
        #expect(mesh.positions.contains { $0.y < -0.9e-7 })
        var edges: [UInt64: Int] = [:]
        for index in stride(from: 0, to: mesh.indices.count, by: 3) {
            for corner in 0..<3 {
                let a = mesh.indices[index + corner], b = mesh.indices[index + (corner + 1) % 3]
                edges[(UInt64(min(a, b)) << 32) | UInt64(max(a, b)), default: 0] += 1
            }
        }
        #expect(edges.values.allSatisfy { $0 == 2 })
    }
}
