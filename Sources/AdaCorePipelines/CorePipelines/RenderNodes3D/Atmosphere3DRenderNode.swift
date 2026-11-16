import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

/// Builds the sky tables of the physical atmosphere: transmittance and multiple scattering when the medium changes,
/// the sky-view and aerial-perspective tables every frame.
///
/// Runs after the main pass and before the environment composite, which reads the tables. A camera whose atmosphere is
/// off, or one showing a full-screen debug view, records no GPU work and holds no texture.
public struct Atmosphere3DRenderNode: RenderNode {
    public static let name: RenderNodeLabel = "Main3D.Atmosphere"

    @Query<Entity, Camera, RenderViewTarget, GlobalViewUniform, ExtractedCameraSource> private var views
    @Res<ExtractedEnvironment3D> private var environments
    @Res<ExtractedLighting3D> private var lighting
    @ResMut<Atmosphere3DViews> private var atmosphereViews
    @Res<RenderDeviceHandler> private var device
    @Res<Render3DPerformanceMetrics?> private var metrics

    public init() {}

    public func update(from world: World) {
        views.update(from: world)
        _environments.update(from: world)
        _lighting.update(from: world)
        _atmosphereViews.update(from: world)
        _device.update(from: world)
        _metrics.update(from: world)
        var activeViews: [Entity.ID] = []
        views.forEach { _, _, _, _, source in activeViews.append(source.entityId) }
        atmosphereViews.retainViews(activeViews)
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity else {
            return []
        }
        var submitted: CommandBuffer?
        views.forEach { entity, _, target, viewUniform, source in
            guard entity == view else {
                return
            }
            guard let environment = environments.environments[source.entityId], environment.atmosphere.changesImage,
                !environment.debugView.replacesFinalImage, target.rendering3DUsesEnvironmentTargets
            else {
                atmosphereViews.discard(view: source.entityId)
                metrics?.record(memory: "atmosphere", bytes: atmosphereViews.store.memoryBytes)
                return
            }
            let settings = environment.atmosphere.sanitized
            let sun = Atmosphere3DSun(light: lighting.directionalLight, settings: settings)
            let packed = Atmosphere3DUniform(
                atmosphere: settings,
                sunDirection: sun.direction,
                sunRadiance: sun.radiance,
                inverseView: viewUniform.viewMatrix.inverse,
                inverseProjection: viewUniform.projectionMatrix.inverse,
                cameraAltitude: viewUniform.viewMatrix.inverse.origin.y
            )
            let tables = atmosphereViews.store.tables(forView: source.entityId, tier: .tier(for: settings.quality))
            let mediumKey = Atmosphere3DUniform.staticKey(for: settings)
            let rebuildsMedium = atmosphereViews.store.claimStaticUpdate(view: source.entityId, key: mediumKey)
            let redraws = atmosphereViews.store.claimFrameUpdates(view: source.entityId, uniform: packed, key: mediumKey)
            if let metrics {
                metrics.record(memory: "atmosphere", bytes: atmosphereViews.store.memoryBytes)
            }
            // A still camera under a still sun keeps last frame's tables and records no GPU work.
            guard rebuildsMedium || redraws.sky || redraws.aerial else {
                return
            }
            let constants = atmosphereViews.uniform.write(packed, view: source.entityId, device: device.renderDevice)
            let command = renderContext.commandQueue.makeCommandBuffer()
            command.label = "Atmosphere 3D"
            // Every pass binds the same three slots; a table that is not an input yet is replaced by a white texture
            // so a pass never samples the texture it writes.
            func draw(
                _ label: String, into output: RenderTexture, and second: RenderTexture? = nil, pipeline: RenderPipeline, transmittance: Texture, multiScatter: Texture
            ) {
                let operation = OperationDescriptor(loadAction: .clear, storeAction: .store)
                let pass = command.beginRenderPass(RenderPassDescriptor(
                    label: label,
                    colorAttachments: ([output] + (second.map { [$0] } ?? [])).map { .init(texture: $0, operation: operation, clearColor: .black) },
                    depthStencilAttachment: nil
                ))
                pass.setViewport(Rect(x: 0, y: 0, width: Float(output.size.width), height: Float(output.size.height)))
                pass.setRenderPipelineState(pipeline)
                pass.setFragmentBuffer(constants, offset: 0, slot: 4)
                pass.setResourceSet(RenderResourceSet(bindings: [
                    .init(binding: 0, shaderStages: .fragment, resource: .texture(transmittance)),
                    .init(binding: 1, shaderStages: .fragment, resource: .texture(multiScatter)),
                    .init(binding: 2, shaderStages: .fragment, resource: .sampler(atmosphereViews.sampler)),
                ]), index: 0)
                pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
                pass.endRenderPass()
            }
            let white = Texture2D.whiteTexture
            if rebuildsMedium {
                draw("Atmosphere Transmittance", into: tables.transmittance, pipeline: atmosphereViews.transmittancePipeline, transmittance: white, multiScatter: white)
                draw("Atmosphere Multiple Scattering", into: tables.multiScatter, pipeline: atmosphereViews.multiScatterPipeline, transmittance: tables.transmittance, multiScatter: white)
            }
            if redraws.sky {
                draw("Atmosphere Sky View", into: tables.skyView, pipeline: atmosphereViews.skyViewPipeline, transmittance: tables.transmittance, multiScatter: tables.multiScatter)
            }
            if redraws.aerial {
                draw(
                    "Atmosphere Aerial Perspective", into: tables.aerial, and: tables.aerialTransmittance,
                    pipeline: atmosphereViews.aerialPipeline, transmittance: tables.transmittance, multiScatter: tables.multiScatter
                )
            }
            if let metrics {
                command.addCompletedTimingHandler { metrics.record(pass: "atmosphere", seconds: $0) }
            }
            submitted = command
        }
        if let submitted {
            if let metrics { await metrics.commit(submitted) } else { submitted.commit() }
        }
        return []
    }
}
