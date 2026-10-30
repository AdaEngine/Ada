import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

/// Alpha-blended smoke billboards in HDR, after opaque geometry and before fog/tone mapping.
/// Depth is sampled for soft intersections and never written by transparent particles.
public struct Particles3DRenderNode: RenderNode {
    public static let name: RenderNodeLabel = "Main3D.Particles"
    @Query<Entity, Camera, RenderViewTarget, GlobalViewUniform, ExtractedCameraSource> private var views
    @Res<ExtractedParticles3D> private var particles
    @Res<ExtractedLighting3D> private var lighting
    @ResMut<Particles3DResources> private var resources
    @Res<RenderDeviceHandler> private var device
    public init() {}

    public func update(from world: World) {
        views.update(from: world)
        _particles.update(from: world)
        _lighting.update(from: world)
        _resources.update(from: world)
        _device.update(from: world)
        var active: [Entity.ID] = []
        views.forEach { _, _, _, _, source in active.append(source.entityId) }
        resources.retainViews(active)
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity, !particles.samples.isEmpty else { return [] }
        var submitted: CommandBuffer?
        try views.forEach { entity, camera, target, uniform, source in
            guard entity == view, let color = target.sceneColor3DTexture,
                let positions = target.viewPositionMetallic3DTexture else { return }
            let instances = resources.prepare(particles.samples, view: source.entityId, matrix: uniform.viewMatrix, device: device.renderDevice)
            guard !instances.isEmpty else { return }
            let constants = resources.uniforms.write(temporalViewUniform(uniform, target: target), view: source.entityId, device: device.renderDevice)
            // Read shadow state after its graph node executed, so moving flashes never sample old matrices.
            let shadows = context.world.getResource(LocalShadow3DViews.self)?.entries[source.entityId]
            let lightConstants = resources.lighting.write(view: source.entityId, count: ParticleLighting3D.vectorCount, device: device.renderDevice) {
                ParticleLighting3D.pack(_lighting.wrappedValue, view: uniform.viewMatrix, shadows: shadows, into: &$0)
            }
            let shadowConstants = resources.lighting.write(view: source.entityId, pass: 1, count: 97, device: device.renderDevice) {
                packLocalShadowMatrices(shadows, into: &$0)
            }
            let shadowTexture = shadows?.color ?? Texture2D.whiteTexture
            let command = renderContext.commandQueue.makeCommandBuffer()
            command.label = "Particles 3D"
            var attachments = [RenderPassColorAttachmentDescriptor(texture: color, operation: .init(loadAction: .load, storeAction: .store))]
            if let indirect = target.indirectLighting3DTexture {
                attachments.append(.init(texture: indirect, operation: .init(loadAction: .load, storeAction: .store)))
                if let response = target.reflectionResponse3DTexture {
                    attachments.append(.init(texture: response, operation: .init(loadAction: .load, storeAction: .store)))
                }
            }
            let pipeline = try resources.pipeline(device: device.renderDevice, attachments: attachments.count)
            let pass = command.beginRenderPass(RenderPassDescriptor(
                label: "Particles 3D",
                colorAttachments: attachments
            ))
            pass.setRenderPipelineState(pipeline)
            pass.setVertexBuffer(constants, offset: 0, slot: GlobalBufferIndex.viewUniform)
            pass.setVertexBuffer(instances, offset: 0, slot: 0)
            pass.setFragmentBuffer(lightConstants, offset: 0, slot: 4)
            pass.setFragmentBuffer(shadowConstants, offset: 0, slot: 5)
            pass.setResourceSet(RenderResourceSet(bindings: [
                .init(binding: 0, shaderStages: .fragment, resource: .texture(positions)),
                .init(binding: 1, shaderStages: .fragment, resource: .sampler(positions.sampler)),
                .init(binding: 6, shaderStages: .fragment, resource: .texture(shadowTexture)),
                .init(binding: 7, shaderStages: .fragment, resource: .sampler(shadowTexture.sampler))
            ]), index: 0)
            pass.setViewport(camera.viewport.rect)
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instances.count)
            pass.endRenderPass()
            submitted = command
        }
        submitted?.commit()
        return []
    }
}

struct Particle3DInstance: Sendable {
    var centerSize: Vector4
    var color: Vector4
    var parameters: Vector4
}

struct Particles3DResources: Resource {
    private struct Frames {
        var buffers: [BufferData<Particle3DInstance>]
        var index = 0
    }
    private var views: [Entity.ID: Frames] = [:]
    private var cachedPipelines: [Int: RenderPipeline] = [:]
    var uniforms = FrameUniformCache3D<GlobalViewUniform>()
    var lighting = LocalLighting3DGPUScratch()

    mutating func retainViews(_ active: [Entity.ID]) {
        for id in views.keys where !active.contains(id) { views.removeValue(forKey: id) }
        uniforms.retainViews(active)
        lighting.retainViews(active)
    }

    mutating func prepare(_ samples: [Particle3DSample], view: Entity.ID, matrix: Transform3D, device: RenderDevice) -> BufferData<Particle3DInstance> {
        let count = max(1, unsafe RenderEngine.configurations.maxFramesInFlight)
        var frames = views.removeValue(forKey: view) ?? Frames(buffers: (0..<count).map { _ in BufferData(elements: []) })
        frames.index = (frames.index + 1) % frames.buffers.count
        frames.buffers[frames.index].elements.removeAll(keepingCapacity: true)
        for sample in samples.prefix(65_536) {
            let center = (matrix * Vector4(sample.position, 1)).xyz
            guard center.x.isFinite, center.y.isFinite, center.z.isFinite, center.z > 0, sample.size.isFinite, sample.size > 0,
                sample.color.x.isFinite, sample.color.y.isFinite, sample.color.z.isFinite, sample.opacity.isFinite, sample.opacity > 0,
                sample.rotation.isFinite, sample.softDistance.isFinite else { continue }
            var angle = sample.rotation
            var length = sample.size
            var aspect = sample.style == 1 ? sample.aspectRatio : 1
            if sample.style == 1 {
                let velocity = (matrix * Vector4(sample.velocity, 0)).xyz
                angle = Math.atan2(-velocity.x, velocity.y)
                // Streaks foreshorten when looking along their world-space fall direction.
                let total = max(sample.velocity.length, 0.001)
                let foreshorten = max(0.08, min(1, Math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y) / total))
                length *= foreshorten
                aspect = min(1, aspect / foreshorten)
            }
            frames.buffers[frames.index].elements.append(Particle3DInstance(
                centerSize: Vector4(center, length), color: Vector4(sample.color, min(sample.opacity, 1)),
                parameters: [angle, max(sample.softDistance, 0.001), aspect, Float(sample.style)]
            ))
        }
        // View-space positive Z: farthest first, across all emitters.
        frames.buffers[frames.index].elements.sort { $0.centerSize.z > $1.centerSize.z }
        if !frames.buffers[frames.index].isEmpty { frames.buffers[frames.index].write(to: device) }
        let result = frames.buffers[frames.index]
        views[view] = frames
        return result
    }

    mutating func pipeline(device: RenderDevice, attachments: Int) throws -> any RenderPipeline {
        if let cached = cachedPipelines[attachments] { return cached }
        var defines: [String] = []
        if attachments >= 2 { defines.append("PARTICLE_INDIRECT") }
        if attachments >= 3 { defines.append("PARTICLE_REFLECTION_RESPONSE") }
        let shader = try ShaderModule.createBundled(at: "Shaders/particles_3d.glsl", from: .adaModule, defines: defines)
        var vertex = VertexDescriptor()
        vertex.attributes[0] = .attribute(.vector4, name: "centerSize", bufferIndex: 0, offset: 0)
        vertex.attributes[1] = .attribute(.vector4, name: "color", bufferIndex: 0, offset: 16)
        vertex.attributes[2] = .attribute(.vector4, name: "parameters", bufferIndex: 0, offset: 32)
        vertex.layouts[0] = .init(stride: MemoryLayout<Particle3DInstance>.stride, stepFunction: .perInstance)
        var descriptor = RenderPipelineDescriptor(
            vertex: shader.requiredShader(for: .vertex), fragment: shader.getShader(for: .fragment),
            debugName: "Soft Particles 3D", backfaceCulling: false, vertexDescriptor: vertex,
            depthPixelFormat: .none, colorAttachments: [.init(format: .rgba_16f, isBlendingEnabled: true)]
        )
        for _ in 1..<attachments {
            descriptor.colorAttachments.append(.init(
                format: .rgba_16f, isBlendingEnabled: true, sourceRGBBlendFactor: .zero,
                sourceAlphaBlendFactor: .zero, destinationAlphaBlendFactor: .one
            ))
        }
        let result = device.createRenderPipeline(from: descriptor)
        cachedPipelines[attachments] = result
        return result
    }
}
