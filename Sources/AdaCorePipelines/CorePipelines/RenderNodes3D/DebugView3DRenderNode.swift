import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

/// Replaces the final 3D image with the camera's ``DebugView3D`` visualization.
///
/// Runs after the last color writer (SSR composite, FXAA or temporal resolve) and before 2D/UI, so debug
/// output is never anti-aliased, tone mapped or upscaled. Cameras with ``DebugView3D/none`` or
/// ``DebugView3D/wireframe`` return immediately and record no GPU work.
public struct DebugView3DRenderNode: RenderNode {
    public static let name: RenderNodeLabel = "Main3D.DebugView"

    @Query<Entity, Camera, RenderViewTarget, ExtractedCameraSource> private var views
    @Res<ExtractedEnvironment3D> private var environments
    @ResMut<DebugView3DPipelines> private var pipelines
    @Res<RenderDeviceHandler> private var device
    @Res<Render3DPerformanceMetrics?> private var metrics
    @Res<ExtractedDebugLines3D> private var overlays
    private let notifiesCompletion: Bool

    public init(notifiesCompletion: Bool = true) { self.notifiesCompletion = notifiesCompletion }

    public func update(from world: World) {
        views.update(from: world)
        _environments.update(from: world)
        _pipelines.update(from: world)
        _device.update(from: world)
        _metrics.update(from: world)
        _overlays.update(from: world)
        var activeViews: [Entity.ID] = []
        views.forEach { _, _, _, source in activeViews.append(source.entityId) }
        pipelines.uniform.retainViews(activeViews)
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity else {
            return []
        }
        var submitted: CommandBuffer?
        views.forEach { entity, camera, target, source in
            guard entity == view,
                let mode = environments.environments[source.entityId]?.debugView, mode.replacesFinalImage,
                let normalRoughness = target.normalRoughness3DTexture,
                let viewPositionMetallic = target.viewPositionMetallic3DTexture,
                let sceneColor = target.sceneColor3DTexture,
                let output = target.mainTexture
            else { return }
            let constants = pipelines.uniform.write(Vector4(mode.shaderMode, 0.2, 0, 0), view: source.entityId, device: device.renderDevice)
            let command = renderContext.commandQueue.makeCommandBuffer()
            command.label = "Debug View 3D"
            let pass = command.beginRenderPass(RenderPassDescriptor(
                label: "Debug View 3D",
                colorAttachments: [.init(texture: output, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .black)],
                depthStencilAttachment: nil
            ))
            pass.setViewport(target.temporalUpscalingActive
                ? Rect(x: 0, y: 0, width: Float(output.size.width), height: Float(output.size.height)) : camera.viewport.rect)
            pass.setRenderPipelineState(pipelines.pipeline(device: device.renderDevice))
            pass.setFragmentBuffer(constants, offset: 0, slot: 5)
            pass.setResourceSet(RenderResourceSet(bindings: [
                .init(binding: 0, shaderStages: .fragment, resource: .texture(normalRoughness)),
                .init(binding: 1, shaderStages: .fragment, resource: .texture(viewPositionMetallic)),
                .init(binding: 2, shaderStages: .fragment, resource: .texture(target.ambientOcclusion3DTexture ?? Texture2D.whiteTexture)),
                .init(binding: 3, shaderStages: .fragment, resource: .texture(target.indirectLighting3DTexture ?? Texture2D.whiteTexture)),
                .init(binding: 4, shaderStages: .fragment, resource: .sampler(pipelines.nearest)),
                .init(binding: 6, shaderStages: .fragment, resource: .texture(sceneColor)),
            ]), index: 0)
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            pass.endRenderPass()
            if notifiesCompletion, !overlays.hasOverlay, let drawable = target.outputTexture, drawable === output {
                command.addCompletedHandler { [drawable] in drawable.notifyRenderCompleted() }
            }
            if let metrics {
                command.addCompletedTimingHandler { metrics.record(pass: "debug", seconds: $0) }
            }
            submitted = command
        }
        if let submitted {
            if let metrics { await metrics.commit(submitted) } else { submitted.commit() }
        }
        return []
    }
}

/// Fullscreen pipeline and per-view uniforms for ``DebugView3DRenderNode``.
struct DebugView3DPipelines: Resource {
    var uniform = FrameUniformCache3D<Vector4>()
    let nearest: Sampler
    private var cached: RenderPipeline?

    init(device: RenderDevice) {
        nearest = device.createSampler(from: .init(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped))
    }

    mutating func pipeline(device: RenderDevice) -> RenderPipeline {
        if let cached {
            return cached
        }
        let shader = CorePipelineShaders.loadRequiredBundled(at: "Shaders/debug_view_3d.glsl")
        var descriptor = RenderPipelineDescriptor(
            vertex: shader.asset.requiredShader(for: .vertex),
            fragment: shader.asset.getShader(for: .fragment),
            debugName: "Debug View 3D",
            backfaceCulling: false,
            depthPixelFormat: .none
        )
        descriptor.colorAttachments = [.init(format: .bgra8)]
        let result = device.createRenderPipeline(from: descriptor)
        cached = result
        return result
    }
}
