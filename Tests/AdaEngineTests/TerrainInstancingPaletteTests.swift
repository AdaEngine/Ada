@_spi(Internal) @testable import AdaApp
@testable import AdaCorePipelines
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Static batches ignore an animated palette belonging to the same entity in portable tracing")
    func staticInstancesIgnoreOwnerSkinInTracing() async throws {
        _ = try await makeApp()
        let device = unsafe RenderEngine.shared.renderDevice
        var descriptor = MeshDescriptor(name: "Rigid prototype with unused skin attributes")
        descriptor.positions = MeshBuffer([Vector3(0, 1, 0), Vector3(-1, -1, 0), Vector3(1, -1, 0)])
        descriptor.normals = MeshBuffer(Array(repeating: Vector3(0, 0, 1), count: 3))
        descriptor[MeshDescriptor.jointIndices] = MeshBuffer(Array(repeating: Vector4.zero, count: 3))
        descriptor[MeshDescriptor.jointWeights] = MeshBuffer(Array(repeating: Vector4(1, 0, 0, 0), count: 3))
        descriptor.indicies = [0, 1, 2]
        let mesh = Mesh.generate(from: [descriptor], renderDevice: device)
        var source = Mesh3DRenderSource(entity: 37, drawPass: Model3DDrawPass(), mesh: mesh, materials: [PBRMaterial()], transform: .identity, bounds: mesh.bounds)
        source.instances = [Mesh3DInstance(id: 90)]
        var skins = Skinning3DUniforms()
        skins.beginFrame(device: device)
        _ = skins.write([Transform3D(translation: [100, 0, 0])], for: source.entity, device: device)
        var scene = PathTracing3DScene()
        try await scene.prepare([source], skinning: skins, device: device)
        #expect(scene.geometryBounds?.center.x == 0)
        let generation = scene.generation
        skins.beginFrame(device: device)
        _ = skins.write([Transform3D(translation: [200, 0, 0])], for: source.entity, device: device)
        try await scene.prepare([source], skinning: skins, device: device)
        #expect(scene.generation == generation)
        #expect(scene.geometryBounds?.center.x == 0)
        // The same real palette remains effective for a source explicitly marked skinned.
        source.instances = nil
        source.skinningBuffer = skins.buffer(for: source.entity)
        try await scene.prepare([source], skinning: skins, device: device)
        #expect(scene.geometryBounds?.center.x == 200)
    }

    @Test("The real model motion draw binds identity for a static batch sharing an animated owner")
    func staticInstancesIgnoreOwnerPreviousSkinInMotion() async throws {
        let app = try await makeApp()
        let device = unsafe RenderEngine.shared.renderDevice
        let render = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
        let view = render.spawn()
        let mesh = Mesh.generateCube(renderDevice: device)
        var source = Mesh3DRenderSource(entity: 83, drawPass: Model3DDrawPass(), mesh: mesh, materials: [PBRMaterial()], transform: .identity, bounds: mesh.bounds)
        source.instances = [Mesh3DInstance(id: 91)]
        var lists = VisibleMesh3DLists(), materials = PBR3DUniforms(), skins = Skinning3DUniforms()
        skins.beginFrame(device: device)
        _ = skins.write([Transform3D(translation: [7, 0, 0])], for: source.entity, device: device)
        skins.beginFrame(device: device)
        _ = skins.write([Transform3D(translation: [9, 0, 0])], for: source.entity, device: device)
        materials.beginFrame()
        lists.prepare(
            sources: [source],
            view: view.id,
            pass: -1,
            viewMatrix: .identity,
            projection: .identity,
            cullingProjection: .identity,
            settings: .init(frustumCulling: false, lod: false, distanceCulling: false),
            device: device,
            materials: &materials
        )
        render.insertResource(materials)
        render.insertResource(skins)
        render.insertResource(lists.buffers(view: view.id, pass: -1))
        render.insertResource(RenderDeviceHandler(renderDevice: device))
        render.insertResource(RenderPipelines(configurator: Motion3DPipeline()))
        var motion = ActiveMotion3DPass()
        motion.isEnabled = true
        render.insertResource(motion)
        let item = try #require(lists.items(view: view.id, pass: -1).first)
        let encoder = TerrainPaletteRecordingEncoder()
        try Model3DDrawPass().render(with: encoder, world: render, view: view, item: item)
        #expect(encoder.drawCount == 1)
        let identity = try #require(skins.identityBuffer)
        #expect(encoder.uniforms[14] === identity)
        #expect(encoder.uniforms[24] === identity)
        let animated = Opaque3DRenderItem(
            entity: item.entity,
            drawPass: item.drawPass,
            sortKey: item.sortKey,
            modelIndex: item.modelIndex,
            partIndex: item.partIndex,
            mesh: item.mesh,
            material: item.material,
            worldTransform: item.worldTransform,
            batchRange: item.batchRange,
            skinningBuffer: skins.buffer(for: source.entity)
        )
        try Model3DDrawPass().render(with: encoder, world: render, view: view, item: animated)
        #expect(encoder.drawCount == 2)
        #expect(encoder.uniforms[24] === skins.previousBuffer(for: source.entity))
    }
}

private final class TerrainPaletteRecordingEncoder: RenderCommandEncoder {
    var uniforms: [Int: any UniformBuffer] = [:]
    var drawCount = 0
    func pushDebugName(_: String) {}
    func popDebugName() {}
    func setRenderPipelineState(_: RenderPipeline) {}
    func setVertexBuffer(_: UniformBuffer, offset _: Int, slot _: Int) {}
    func setVertexBuffer(_: VertexBuffer, offset _: Int, slot _: Int) {}
    func setFragmentBuffer(_: UniformBuffer, offset _: Int, slot _: Int) {}
    func setVertexBuffer<T>(_: BufferData<T>, offset _: Int, slot _: Int) {}
    func setFragmentBuffer<T>(_: BufferData<T>, offset _: Int, slot _: Int) {}
    func setIndexBuffer<T>(_: BufferData<T>, indexFormat _: IndexBufferFormat) {}
    func setVertexBytes(_: UnsafeRawPointer, length _: Int, slot _: Int) {}
    func setFragmentTexture(_: Texture, slot _: Int) {}
    func setFragmentSamplerState(_: Sampler, slot _: Int) {}
    func setResourceSet(_ resourceSet: RenderResourceSet, index _: Int) {
        for binding in resourceSet.bindings {
            if case .uniformBuffer(let buffer, _) = binding.resource { uniforms[binding.binding] = buffer }
        }
    }
    func setViewport(_: Rect) {}
    func setScissorRect(_: Rect) {}
    func setTriangleFillMode(_: TriangleFillMode) {}
    func setIndexBuffer(_: IndexBuffer, offset _: Int) {}
    func drawIndexed(indexCount _: Int, indexBufferOffset _: Int, instanceCount _: Int) { drawCount += 1 }
    func drawIndexed(indexCount _: Int, indexBufferOffset _: Int, instanceCount _: Int, firstInstance _: Int) { drawCount += 1 }
    func draw(type _: IndexPrimitive, vertexStart _: Int, vertexCount _: Int, instanceCount _: Int) {}
    func endRenderPass() {}
}
