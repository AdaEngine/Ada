import AdaEngine
@_spi(Internal) import AdaPhysics
import Testing

@Suite("Thin terrain collision geometry")
struct TerrainThinCollisionTests {
    @Test("Thin triangles above the native cooking limit remain valid collision geometry")
    func thinTriangleCollider() throws {
        let points: [Vector3] = [[0, 0, 0], [1, 0, 0], [0, 0, 0.0000006]]
        let shape = try #require(try? Shape3DResource.generateTriangleMesh(vertices: points, indices: [0, 2, 1]),
            "A triangle above the native area limit must not be rejected by a stricter Swift world-unit cutoff")
        try shape.prepareStaticCollision()
        #expect(throws: Shape3DResource.TriangleMeshError.degenerateTriangle) {
            try Shape3DResource.generateTriangleMesh(vertices: [[0, 0, 0], [1, 0, 0], [2, 0, 0]], indices: [0, 2, 1])
        }
    }
}
