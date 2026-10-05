import AdaECS
import AdaRender
import AdaUtils
import Math

/// Half-resolution SSAO followed by a depth/normal-aware bilateral filter.
public struct ScreenSpaceAO3DRenderNode: RenderNode {
    public static let name: RenderNodeLabel = "Main3D.SSAO"
    @Query<Entity, Camera, RenderViewTarget, GlobalViewUniform, ExtractedCameraSource> private var views
    @Res<ExtractedEnvironment3D> private var environments
    @ResMut<ScreenQuality3DPipelines> private var pipelines
    @ResMut<ScreenQuality3DScratch> private var scratch
    @Res<RenderDeviceHandler> private var device

    @Res<Render3DPerformanceMetrics?> private var metrics

    public init() {}
    public func update(from world: World) {
        _metrics.update(from: world)
        views.update(from: world)
        _environments.update(from: world)
        _pipelines.update(from: world)
        _scratch.update(from: world)
        _device.update(from: world)
        var activeViews: [Entity.ID] = []
        views.forEach { _, _, _, _, source in activeViews.append(source.entityId) }
        scratch.ao.retainViews(activeViews)
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity else {
            return []
        }
        var submitted: CommandBuffer?
        views.forEach { entity, _, target, uniform, source in
            let settings = environments.environments[source.entityId]?.ambientOcclusion ?? ScreenSpaceAO3D()
            guard entity == view, settings.isEnabled,
                let position = target.viewPositionMetallic3DTexture, let normal = target.normalRoughness3DTexture,
                let raw = target.ambientOcclusion3DRawTexture, let filtered = target.ambientOcclusion3DTexture
            else { return }
            let parameters = Vector4(
                finiteRenderValue(settings.radius, fallback: 0.65, range: 0.05...3),
                finiteRenderValue(settings.intensity, fallback: 1.1, range: 0...3),
                finiteRenderValue(settings.bias, fallback: 0.025, range: 0.001...0.2),
                Float(min(max(settings.sampleCount, 8), 32))
            )
            let command = renderContext.commandQueue.makeCommandBuffer()
            command.label = "SSAO 3D + Bilateral"
            for index in 0..<2 {
                let output = index == 0 ? raw : filtered
                let constants = scratch.ao.write(
                    SSAO3DUniform(projection: temporalViewUniform(uniform, target: target).projectionMatrix, parameters: parameters, pass: Vector4(Float(index), 0, 0, 0)),
                    view: source.entityId,
                    pass: index,
                    device: device.renderDevice
                )
                let pass = command.beginRenderPass(RenderPassDescriptor(
                    label: index == 0 ? "SSAO 3D" : "SSAO Bilateral",
                    colorAttachments: [.init(texture: output, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .white)],
                    depthStencilAttachment: nil
                ))
                pass.setViewport(Rect(x: 0, y: 0, width: Float(output.size.width), height: Float(output.size.height)))
                pass.setRenderPipelineState(pipelines.aoPipeline(device: device.renderDevice))
                pass.setFragmentBuffer(constants, offset: 0, slot: 4)
                pass.setResourceSet(RenderResourceSet(bindings: [
                    .init(binding: 0, shaderStages: .fragment, resource: .texture(position)),
                    .init(binding: 1, shaderStages: .fragment, resource: .texture(normal)),
                    .init(binding: 2, shaderStages: .fragment, resource: .texture(index == 0 ? Texture2D.whiteTexture : raw)),
                    .init(binding: 3, shaderStages: .fragment, resource: .sampler(pipelines.nearest)),
                ]), index: 0)
                pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
                pass.endRenderPass()
            }
            if let metrics {
                command.addCompletedTimingHandler { metrics.record(pass: "ssao", seconds: $0) }
            }
            submitted = command
        }
        if let submitted {
            if let metrics { await metrics.commit(submitted) } else { submitted.commit() }
        }
        return []
    }
}
