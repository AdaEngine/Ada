import AdaEngine
@_spi(Internal) @testable import AdaRender
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Sparse indexed operands reserve the complete imported position accessor before copying it")
    func volumeModelBoundsSparseAccessorCopy() async throws {
        _ = try await makeApp()
        let device = unsafe RenderEngine.shared.renderDevice
        let cube = Mesh.generateCube(renderDevice: device)
        let original = try #require(cube.models.first?.parts.first?.meshDescriptor)
        var descriptor = MeshDescriptor(name: "Closed cube with unused imported rows")
        descriptor.positions = MeshBuffer(original.positions.elements + Array(repeating: Vector3(50, 50, 50), count: 8_192))
        descriptor.indicies = original.indicies
        let model = ModelAsset3D(
            nodes: [.init(name: "Solid", transform: .identity, meshIndex: 0, children: [])],
            meshes: [Mesh.generate(from: [descriptor], renderDevice: device)],
            materials: [PBRMaterial()],
            scenes: [[0]],
            defaultScene: 0
        )
        let prototype = try TerrainMeshPrototype(model: model)
        let oldAllowance = prototype.retainedGeometryBytes + descriptor.indicies.count * 512
        let copyBytes = descriptor.positions.count * MemoryLayout<Vector3>.stride
        let operation = TerrainVolumeOperation(operation: .union, operand: .mesh(assetPath: "sparse.gltf", scene: nil))
        #expect(throws: TerrainVolumeFieldError.memoryBudgetExceeded) {
            try TerrainVolumePreparedMesh(operation: operation, model: model, maximumBytes: oldAllowance)
        }
        let admitted = try? TerrainVolumePreparedMesh(operation: operation, model: model, maximumBytes: oldAllowance + copyBytes)
        #expect(admitted != nil, "A closed sparse model remains valid when all position-copy staging is explicitly reserved")
    }
}
