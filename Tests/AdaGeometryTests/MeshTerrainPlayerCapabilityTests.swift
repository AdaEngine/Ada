import AdaGeometry
import Math
import Testing

@Suite struct MeshTerrainPlayerCapabilityTests {
    @Test func nativeAuthoringIsAnExplicitPackageCapability() throws {
        #if MESH_TERRAIN_AUTHORING
        #expect(TriangleMeshBoolean.isAvailable)
        #else
        #expect(!TriangleMeshBoolean.isAvailable)
        let surface = try TriangleSurface.box(minimum: [-1, -1, -1], maximum: [1, 1, 1])
        #expect(throws: TriangleGeometryError.kernelUnavailable) {
            try TriangleMeshBoolean.apply(.union, base: surface, operand: surface)
        }
        #endif
    }
}
