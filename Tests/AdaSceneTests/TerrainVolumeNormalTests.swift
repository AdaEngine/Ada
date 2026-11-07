import AdaAssets
@testable import AdaScene
import Math
import Testing

@Suite("Canonical volume shading")
struct TerrainVolumeNormalTests {
    @Test("Adjacent bricks use identical outward normals on their shared curved surface")
    func sharedNormals() throws {
        let base = try TerrainHeightStorage(importing: Terrain3D(resolution: 65, size: 64))
        let operation = TerrainVolumeOperation(operation: .union, operand: .primitive(.sphere(radius: 5)), transform: .init(translation: [0.3, 9.2, 0.7]))
        let field = try TerrainVolumeField(document: .init(cellSize: 1, origin: [0, 0, -16], operations: [operation]), base: base)
        let left = try field.surface(of: field.makeBrick(x: -1, y: 0, z: 0))
        let right = try field.surface(of: field.makeBrick(x: 0, y: 0, z: 0))
        let a = try field.canonicalNormals(for: left), b = try field.canonicalNormals(for: right)
        var border: [Vector3: Vector3] = [:]
        for index in left.positions.indices where left.positions[index].x == 0 && left.positions[index].y > 3 {
            border[left.positions[index]] = a[index]
        }
        var shared = 0
        for index in right.positions.indices {
            let point = right.positions[index]
            guard let expected = border[point] else { continue }
            shared += 1
            #expect(b[index] == expected, "A shared position must have the same shading normal independent of brick ownership")
            let radial = (point - Vector3(0.3, 9.2, 0.7)).normalized
            #expect(b[index].dot(radial) > 0.99)
        }
        #expect(shared > 12)
    }
}
