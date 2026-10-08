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
    func terrainChunkLODsShareAllBoundaryVerticesAndReduceTriangles() {
        let terrain = GardenTerrain()
        let descriptors = [1, 2, 4].map { terrain.chunkDescriptor(column: 5, row: 4, step: $0) }
        let minimum = Vector3(6, 0, 0), maximum = Vector3(12, 0, 6)
        func boundary(_ descriptor: MeshDescriptor) -> Set<Vector3> {
            Set(Array(descriptor.positions).filter { abs($0.x - minimum.x) < 0.001 || abs($0.x - maximum.x) < 0.001 || abs($0.z - minimum.z) < 0.001 || abs($0.z - maximum.z) < 0.001 })
        }
        #expect(boundary(descriptors[0]) == boundary(descriptors[1]))
        #expect(boundary(descriptors[0]) == boundary(descriptors[2]))
        #expect(descriptors[0].indicies.count > descriptors[1].indicies.count)
        #expect(descriptors[1].indicies.count > descriptors[2].indicies.count)
        // Adjacent chunks at different LODs keep the exact same shared edge.
        let neighbor = terrain.chunkDescriptor(column: 6, row: 4, step: 1)
        let firstEdge = Set(Array(descriptors[2].positions).filter { abs($0.x - 12) < 0.001 })
        let secondEdge = Set(Array(neighbor.positions).filter { abs($0.x - 12) < 0.001 })
        #expect(firstEdge == secondEdge)
    }

    @Test
    func placementsAreReproducibleAndSurfaceSamplerFollowsTriangles() {
        var first = GardenRandom(), second = GardenRandom()
        for _ in 0 ..< 100 { #expect(first.next(-23, 23) == second.next(-23, 23)) }
        let terrain = GardenTerrain()
        let cell = 42 * 65 + 44
        let a = terrain.vertices[cell], b = terrain.vertices[cell + 65], c = terrain.vertices[cell + 66]
        let point = a * 0.4 + b * 0.3 + c * 0.3
        #expect(abs(terrain.surfaceHeight(x: point.x, z: point.z) - point.y) < 0.0001)
    }
}
