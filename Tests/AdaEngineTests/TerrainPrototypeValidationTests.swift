import AdaEngine
@_spi(Internal) @testable import AdaRender
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Prototype preparation rejects malformed indexed geometry before it becomes a reusable batch")
    func terrainPrototypeRejectsUnsafeGeometry() async throws {
        _ = try await makeApp()
        let device = unsafe RenderEngine.shared.renderDevice
        var descriptor = MeshDescriptor(name: "Triangle")
        descriptor.positions = MeshBuffer([Vector3(0, 1, 0), Vector3(-1, -1, 0), Vector3(1, -1, 0)])
        descriptor.indicies = [0, 1, 2]
        let original = Mesh.generate(from: [descriptor], renderDevice: device)
        let part = try #require(original.models.first?.parts.first)
        func model(_ mesh: Mesh) -> ModelAsset3D {
            ModelAsset3D(nodes: [.init(name: nil, transform: .identity, meshIndex: 0, children: [])], meshes: [mesh], materials: [PBRMaterial()], scenes: [[0]], defaultScene: 0)
        }
        descriptor.indicies = [0, 1, UInt32.max]
        let missingVertex = Mesh.generate(from: [descriptor], renderDevice: device)
        #expect(throws: TerrainMeshPrototypeError.unsupportedGeometry) { try TerrainMeshPrototype(model: model(missingVertex)) }
        var excessive = part
        excessive.indexCount = 6
        #expect(throws: TerrainMeshPrototypeError.unsupportedGeometry) {
            try TerrainMeshPrototype(model: model(Mesh(models: [Mesh.Model(name: "Draw past end", parts: [excessive])])))
        }
        var shortBuffer = part
        var oneIndex: UInt32 = 0
        shortBuffer.indexBuffer = unsafe device.createIndexBuffer(format: .uInt32, bytes: &oneIndex, length: MemoryLayout<UInt32>.stride)
        #expect(throws: TerrainMeshPrototypeError.unsupportedGeometry) {
            try TerrainMeshPrototype(model: model(Mesh(models: [Mesh.Model(name: "Short index storage", parts: [shortBuffer])])))
        }
        var shortVertices = part
        shortVertices.vertexBuffer = device.createVertexBuffer(length: 1, binding: 0)
        #expect(throws: TerrainMeshPrototypeError.unsupportedGeometry) {
            try TerrainMeshPrototype(model: model(Mesh(models: [Mesh.Model(name: "Short vertex storage", parts: [shortVertices])])))
        }
        descriptor.indicies = [0, 1, 2]
        descriptor.positions = MeshBuffer([Vector3(0, 1, 0), Vector3(.nan, 0, 0), Vector3(-1, -1, 0), Vector3(1, -1, 0)])
        let nonfinite = Mesh.generate(from: [descriptor], renderDevice: device)
        #expect(throws: TerrainMeshPrototypeError.unsupportedGeometry) { try TerrainMeshPrototype(model: model(nonfinite)) }
        descriptor.positions = part.meshDescriptor.positions
        descriptor.textureCoordinates = MeshBuffer([Vector2(0, 0), Vector2(.infinity, 0), Vector2(1, 1)])
        let invalidUV = Mesh.generate(from: [descriptor], renderDevice: device)
        #expect(throws: TerrainMeshPrototypeError.unsupportedGeometry) { try TerrainMeshPrototype(model: model(invalidUV)) }
    }

    @Test("Finite anisotropic placement matrices cannot produce nonfinite mesh extents")
    func terrainPrototypeRejectsOverflowingPlacementBounds() async throws {
        _ = try await makeApp()
        let mesh = Mesh.generateCube(size: [8, 8, 8], renderDevice: unsafe RenderEngine.shared.renderDevice)
        let model = ModelAsset3D(
            nodes: [.init(name: nil, transform: .identity, meshIndex: 0, children: [])],
            meshes: [mesh],
            materials: [PBRMaterial()],
            scenes: [[0]],
            defaultScene: 0
        )
        let prototype = try TerrainMeshPrototype(model: model)
        let pose = Transform3D(scale: [1e38, 1e-10, 1e-10])
        #expect(throws: TerrainMeshPrototypeError.invalidPlacement) {
            try prototype.makeBatches(instances: [Mesh3DInstance(id: 1, transform: pose)])
        }
    }
}
