import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

/// Spatial anti-aliasing after the environment/tone-map composite and before 2D/UI content.
public struct AntiAliasing3DRenderNode: RenderNode {
    public static let name: RenderNodeLabel = "Main3D.FXAA"
    @Query<Entity, Camera, RenderViewTarget, ExtractedCameraSource> private var views
    @Res<ExtractedEnvironment3D> private var environments
    @ResMut<ScreenQuality3DPipelines> private var pipelines
    @ResMut<ScreenQuality3DScratch> private var scratch
    @Res<RenderDeviceHandler> private var device
    private let notifiesCompletion: Bool

    @Res<Render3DPerformanceMetrics?> private var metrics

    public init(notifiesCompletion: Bool = true) { self.notifiesCompletion = notifiesCompletion }
    public func update(from world: World) {
        _metrics.update(from: world)
        views.update(from: world)
        _environments.update(from: world)
        _pipelines.update(from: world)
        _scratch.update(from: world)
        _device.update(from: world)
        var activeViews: [Entity.ID] = []
        views.forEach { _, _, _, source in activeViews.append(source.entityId) }
        scratch.aa.retainViews(activeViews)
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity else {
            return []
        }
        var submitted: CommandBuffer?
        views.forEach { entity, camera, target, source in
            guard entity == view, environments.environments[source.entityId]?.antiAliasing == .fxaa,
                let input = target.antiAliasing3DInputTexture, let output = target.mainTexture
            else { return }
            let constants = scratch.aa.write(Vector4(1 / Float(input.size.width), 1 / Float(input.size.height), 0, 0), view: source.entityId, device: device.renderDevice)
            let command = renderContext.commandQueue.makeCommandBuffer()
            command.label = "FXAA 3D"
            let pass = command.beginRenderPass(RenderPassDescriptor(
                label: "FXAA 3D", colorAttachments: [.init(texture: output, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .black)], depthStencilAttachment: nil
            ))
            pass.setViewport(camera.viewport.rect)
            pass.setRenderPipelineState(pipelines.aaPipeline(device: device.renderDevice))
            pass.setFragmentBuffer(constants, offset: 0, slot: 2)
            pass.setResourceSet(RenderResourceSet(bindings: [
                .init(binding: 0, shaderStages: .fragment, resource: .texture(input)),
                .init(binding: 1, shaderStages: .fragment, resource: .sampler(pipelines.linear)),
            ]), index: 0)
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            pass.endRenderPass()
            if notifiesCompletion, let drawable = target.outputTexture, drawable === output {
                command.addCompletedHandler { [drawable] in drawable.notifyRenderCompleted() }
            }
            if let metrics {
                command.addCompletedTimingHandler { metrics.record(pass: "fxaa", seconds: $0) }
            }
            submitted = command
        }
        if let submitted {
            if let metrics { await metrics.commit(submitted) } else { submitted.commit() }
        }
        return []
    }
}
