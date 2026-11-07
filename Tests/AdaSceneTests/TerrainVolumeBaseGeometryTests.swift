import AdaAssets
import AdaScene
import Math
import Testing

@Suite("Heightfield base preservation in volume extraction")
struct TerrainVolumeBaseGeometryTests {
    @Test("A steep untouched base meets the original heightfield exactly on an ownership boundary")
    func steepBoundary() throws {
        var terrain = Terrain3D(resolution: 65, size: 64)
        for z in 0...64 {
            for x in 0...64 { terrain.heights[z * 65 + x] = (Float(z) - 32) * 8 + 4 }
        }
        let base = try TerrainHeightStorage(importing: terrain)
        let field = try TerrainVolumeField(document: .init(cellSize: 1), base: base)
        let surface = try field.surface(of: field.makeBrick(x: 0, y: 0, z: 0))
        let boundary = surface.positions.filter { $0.x == 0 }
        try #require(boundary.count > 10)
        let error = try boundary.map { point -> Float in
            let expected = try #require(base.height(at: [point.x, point.z]))
            return abs(point.y - expected)
        }.max() ?? .infinity
        #expect(error < 0.0001)
    }

    @Test("A nonplanar base cell retains the heightfield's high diagonal rather than becoming a valley")
    func nonplanarCellDiagonal() throws {
        var terrain = Terrain3D(resolution: 2, size: 1)
        terrain.heights = [0, 8, 8, 0]
        let base = try TerrainHeightStorage(importing: terrain)
        let field = try TerrainVolumeField(document: .init(cellSize: 1, origin: [-0.5, 0, -0.5]), base: base)
        let surface = try field.surface(of: field.makeBrick(x: 0, y: 0, z: 0))
        let height = try #require(topHeight(surface, x: 0, z: 0))
        let expected = try #require(base.height(at: [0, 0]))
        #expect(abs(height - expected) < 0.0001)
    }

    private func topHeight(_ surface: ScalarSurfaceMesh, x: Double, z: Double) -> Float? {
        var highest: Float?
        for index in stride(from: 0, to: surface.indices.count, by: 3) {
            let a = surface.positions[Int(surface.indices[index])], b = surface.positions[Int(surface.indices[index + 1])], c = surface.positions[Int(surface.indices[index + 2])]
            let abx = Double(b.x) - Double(a.x), abz = Double(b.z) - Double(a.z), acx = Double(c.x) - Double(a.x), acz = Double(c.z) - Double(a.z)
            let area = abx * acz - abz * acx
            guard area != 0 else { continue }
            let dx = x - Double(a.x), dz = z - Double(a.z)
            let u = (dx * acz - dz * acx) / area, v = (abx * dz - abz * dx) / area
            guard u >= -1e-6, v >= -1e-6, u + v <= 1 + 1e-6 else { continue }
            let value = Float(Double(a.y) + u * (Double(b.y) - Double(a.y)) + v * (Double(c.y) - Double(a.y)))
            highest = max(highest ?? -.infinity, value)
        }
        return highest
    }
}
