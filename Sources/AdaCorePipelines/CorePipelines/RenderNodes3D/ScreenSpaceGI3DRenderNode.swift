import AdaAssets
import AdaECS
import AdaRender
import AdaUtils
import Math

public struct ScreenSpaceGI3DRenderNode: RenderNode {
    public static let name: RenderNodeLabel = "Main3D.ScreenSpaceGI"
    @Query<Entity, RenderViewTarget, GlobalViewUniform, ExtractedCameraSource> private var views
    @Res<ExtractedEnvironment3D> private var environments
    @ResMut<ScreenSpaceGI3DViews> private var resources
    @Res<RenderDeviceHandler> private var device
    @Res<Render3DPerformanceMetrics?> private var metrics
    public init() {}

    public func update(from world: World) {
        views.update(from: world); _environments.update(from: world); _resources.update(from: world)
        _device.update(from: world); _metrics.update(from: world)
        var active: [Entity.ID] = []
        views.forEach { _, _, _, source in active.append(source.entityId) }
        resources.retain(active)
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity else { return [] }
        var submitted: CommandBuffer?
        views.forEach { entity, target, uniform, source in
            guard entity == view else { return }
            let settings = (environments.environments[source.entityId]?.screenSpaceGI ?? .init()).sanitized
            guard context.world.getResource(PathTracing3DViews.self)?.entries[source.entityId]?.active != true,
                settings.isEnabled, settings.intensity > 0,
                let surface = target.diffuseSurface3DTexture, let position = target.viewPositionMetallic3DTexture,
                let normal = target.normalRoughness3DTexture, let color = target.sceneColor3DTexture,
                let indirect = target.indirectLighting3DTexture else {
                resources.textures.removeValue(forKey: source.entityId)
                return
            }
            let pair = resources.targets(source.entityId, size: color.size, scale: color.scaleFactor)
            let pipeline = resources.getPipeline(device.renderDevice)
            guard let nearest = resources.nearest else { return }
            let command = renderContext.commandQueue.makeCommandBuffer()
            command.label = "SSGI diffuse transport + bilateral"
            for index in 0..<2 {
                let output = index == 0 ? pair.raw : pair.filtered
                let constants = resources.uniforms.write(ScreenSpaceGI3DUniform(
                    projection: temporalViewUniform(uniform, target: target).projectionMatrix,
                    trace: [settings.maxDistance, settings.thickness, settings.bias, Float(settings.stepCount)],
                    quality: [Float(settings.rayCount), settings.intensity, settings.maximumRadiance, Float(index)]),
                    view: source.entityId, pass: index, device: device.renderDevice)
                let pass = command.beginRenderPass(.init(label: index == 0 ? "SSGI rays" : "SSGI bilateral",
                    colorAttachments: [.init(texture: output, operation: .init(loadAction: .clear, storeAction: .store))]))
                pass.setViewport(Rect(x: 0, y: 0, width: Float(output.size.width), height: Float(output.size.height)))
                pass.setRenderPipelineState(pipeline)
                pass.setFragmentBuffer(constants, offset: 0, slot: 4)
                pass.setResourceSet(.init(bindings: [
                    .init(binding: 0, shaderStages: .fragment, resource: .texture(position)),
                    .init(binding: 1, shaderStages: .fragment, resource: .texture(normal)),
                    .init(binding: 2, shaderStages: .fragment, resource: .texture(color)),
                    .init(binding: 3, shaderStages: .fragment, resource: .texture(surface)),
                    .init(binding: 5, shaderStages: .fragment, resource: .texture(indirect)),
                    .init(binding: 6, shaderStages: .fragment, resource: .texture(index == 0 ? Texture2D.whiteTexture : pair.raw)),
                    .init(binding: 7, shaderStages: .fragment, resource: .sampler(nearest))
                ]), index: 0)
                pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
                pass.endRenderPass()
            }
            if let metrics { command.addCompletedTimingHandler { metrics.record(pass: "ssgi", seconds: $0) } }
            submitted = command
        }
        if let submitted { if let metrics { await metrics.commit(submitted) } else { submitted.commit() } }
        return []
    }
}

struct ScreenSpaceGI3DUniform: Sendable {
    var projection: Transform3D
    var trace: Vector4
    var quality: Vector4
}

struct ScreenSpaceGI3DViews: Resource {
    struct Pair { var raw: RenderTexture; var filtered: RenderTexture }
    var textures: [Entity.ID: Pair] = [:]
    var uniforms = FrameUniformCache3D<ScreenSpaceGI3DUniform>()
    var pipeline: (any RenderPipeline)?
    var nearest: (any Sampler)?
    private var retired: [Pair] = []

    mutating func targets(_ view: Entity.ID, size: SizeInt, scale: Float) -> Pair {
        let half = SizeInt(width: max(1, (size.width+1)/2), height: max(1, (size.height+1)/2))
        if let existing = textures[view], existing.raw.size == half { return existing }
        if let old = textures[view] { retired.append(old) }
        if retired.count > 4 { retired.removeFirst(retired.count-4) }
        let pair = Pair(raw: RenderTexture(size: half, scaleFactor: scale, format: .rgba_16f, debugLabel: "SSGI raw"),
                        filtered: RenderTexture(size: half, scaleFactor: scale, format: .rgba_16f, debugLabel: "SSGI filtered"))
        textures[view] = pair
        return pair
    }
    mutating func retain(_ active: [Entity.ID]) {
        for key in textures.keys where !active.contains(key) { textures.removeValue(forKey: key) }
        uniforms.retainViews(active)
    }
    mutating func getPipeline(_ device: RenderDevice) -> any RenderPipeline {
        if let pipeline { return pipeline }
        let shader = CorePipelineShaders.loadRequiredBundled(at: "Shaders/screen_space_gi_3d.glsl")
        var descriptor = RenderPipelineDescriptor(vertex: shader.asset.requiredShader(for: .vertex), fragment: shader.asset.getShader(for: .fragment),
            debugName: "SSGI diffuse transport", backfaceCulling: false, depthPixelFormat: .none)
        descriptor.colorAttachments = [.init(format: .rgba_16f)]
        let result = device.createRenderPipeline(from: descriptor)
        pipeline = result
        nearest = device.createSampler(from: .init(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped))
        return result
    }
}
