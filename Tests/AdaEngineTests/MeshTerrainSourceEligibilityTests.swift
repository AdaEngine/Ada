@_spi(Internal) @testable import AdaApp
import AdaECS
import AdaGeometry
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaTransform
import Math
import Testing

@MainActor @Suite("Mesh Terrain source part eligibility", .serialized)
struct MeshTerrainSourceEligibilityTests {
    @Test("Default tree join captures the opaque trunk and leaves cutout foliage authored")
    func joinsOnlyOpaqueTreeParts() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let world = World()
        let shape = try TriangleSurface.box(minimum: [-0.25, -1, -0.25], maximum: [0.25, 2, 0.25])
        var trunk = MeshDescriptor(name: "Trunk")
        trunk.positions = .init(shape.positions)
        trunk.indicies = shape.indices
        var canopy = MeshDescriptor(name: "Alpha cutout canopy")
        canopy.positions = .init([[-1, 1, 0], [1, 1, 0], [0, 3, 0]])
        canopy.indicies = [0, 1, 2]
        let renderDevice = unsafe RenderEngine.shared.renderDevice
        let mesh = Mesh.generate(from: [trunk, canopy], renderDevice: renderDevice)
        var parts = try #require(mesh.models.first?.parts)
        parts[1].materialIndex = 1
        let treeMesh = Mesh(models: [.init(name: "Tree", parts: parts)])
        let bark = PBRMaterial(), leaves = PBRMaterial()
        leaves.alphaMode = .mask
        let tree = world.spawn("Tree") { Transform(); Mesh3DComponent(mesh: treeMesh, materials: [bark, leaves]) }
        let captured = try MeshTerrainSourceCapture.capture(tree)
        #expect(captured.surface.indices.count == trunk.indicies.count)
        #expect(captured.drawReplacements.count == 1)
        #expect(captured.drawReplacements.first?.parts == [.init(model: 0, part: 0)])
        #expect(throws: TriangleGeometryError.invalidInput) {
            try MeshTerrainSourceCapture.capture(tree, parts: [.init(nodePath: [], part: 1)])
        }
    }
}
