import AdaEngine
@testable import SkeletalGarden
import Testing

@Suite
struct GardenTerrainTests {
    @Test
    func landscapeIsLargerUnevenAndSharesCollisionVertices() throws {
        let terrain = GardenTerrain()
        #expect(terrain.vertices.count == 65 * 65)
        #expect(terrain.indices.count == 64 * 64 * 6)
        #expect(terrain.vertices.map(\.y).max() ?? 0 > 3)
        #expect(terrain.vertices.map(\.y).min() ?? 0 < -0.5)
        #expect(terrain.surfaceHeight(x: 0, z: 0) == 0)
        #expect(terrain.surfaceHeight(x: -3, z: 4) == 0)
        let collision = try Shape3DResource.generateTriangleMesh(vertices: terrain.vertices, indices: terrain.indices)
        #expect(collision != .generateBox())
        for point in terrain.vertices {
            #expect(abs(terrain.surfaceHeight(x: point.x, z: point.z) - point.y) < 0.001)
        }
        let descriptor = terrain.descriptor()
        #expect(descriptor.indicies.count < terrain.indices.count)
        #expect(descriptor.normals?.count == terrain.vertices.count)
        #expect(descriptor.colors?.count == terrain.vertices.count)
    }

    @Test
    func placementsAreReproducibleAndSurfaceSamplerFollowsTriangles() {
        var first = GardenRandom(), second = GardenRandom()
        for _ in 0..<100 { #expect(first.next(-23, 23) == second.next(-23, 23)) }
        let terrain = GardenTerrain()
        let cell = 42 * 65 + 44
        let a = terrain.vertices[cell], b = terrain.vertices[cell + 65], c = terrain.vertices[cell + 66]
        let point = a * 0.4 + b * 0.3 + c * 0.3
        #expect(abs(terrain.surfaceHeight(x: point.x, z: point.z) - point.y) < 0.0001)
    }
}
