import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

/// Raymarches the atmosphere's cloud layer at reduced resolution and blends it with the previous frame.
///
/// Runs after the atmosphere tables are built and before the environment composite, which draws the result over the sky.
/// A camera without active clouds, without atmosphere tables, or one showing a full-screen debug view records no GPU
/// work and holds no cloud texture.
public struct Clouds3DRenderNode: RenderNode {
    public static let name: RenderNodeLabel = "Main3D.Clouds"

    @Query<Entity, Camera, RenderViewTarget, GlobalViewUniform, ExtractedCameraSource> private var views
    @Res<ExtractedEnvironment3D> private var environments
    @Res<ExtractedLighting3D> private var lighting
    @Res<Atmosphere3DViews> private var atmosphereViews
    @ResMut<Clouds3DViews> private var cloudViews
    @Res<RenderDeviceHandler> private var device
    @Res<Render3DPerformanceMetrics?> private var metrics

    public init() {}

    public func update(from world: World) {
        views.update(from: world)
        _environments.update(from: world)
        _lighting.update(from: world)
        _atmosphereViews.update(from: world)
        _cloudViews.update(from: world)
        _device.update(from: world)
        _metrics.update(from: world)
        var activeViews: [Entity.ID] = []
        views.forEach { _, _, _, _, source in activeViews.append(source.entityId) }
        cloudViews.retainViews(activeViews)
        cloudViews.advanceFrame()
        // Noise for seeds no camera uses any more is released.
        var seeds: Set<UInt32> = []
        for environment in environments.environments.values where environment.atmosphere.cloudsActive {
            seeds.insert(environment.atmosphere.clouds.seed)
        }
        cloudViews.noise.retain(seeds: seeds)
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
            guard let environment = environments.environments[source.entityId], environment.atmosphere.cloudsActive,
                !environment.debugView.replacesFinalImage, target.rendering3DUsesEnvironmentTargets,
                let tables = atmosphereViews.tables(view: source.entityId), let size = target.mainTexture?.size
            else {
                cloudViews.discard(view: source.entityId)
                metrics?.record(memory: "clouds", bytes: cloudViews.memoryBytes)
                return
            }
            let atmosphere = environment.atmosphere.sanitized
            let clouds = atmosphere.clouds
            let tier = Clouds3DTier.tier(for: clouds.quality)
            let inverseView = viewUniform.viewMatrix.inverse
            let viewProjection = viewUniform.projectionMatrix * viewUniform.viewMatrix
            let frame = cloudViews.store.begin(
                view: source.entityId,
                key: Clouds3DKey(tier: tier, size: tier.size(for: size)),
                position: inverseView.origin,
                forward: Vector3(inverseView[2].x, inverseView[2].y, inverseView[2].z).normalized,
                viewProjection: viewProjection
            )
            let noiseTextures = cloudViews.noise.textures(forSeed: clouds.seed)
            let buildsNoise = cloudViews.noise.claimBuild(seed: clouds.seed)
            let sun = Atmosphere3DSun(light: lighting.directionalLight, settings: atmosphere)
            let renderDevice = device.renderDevice
            let atmosphereConstants = cloudViews.atmosphereUniform.write(
                Atmosphere3DUniform(
                    atmosphere: atmosphere, sunDirection: sun.direction, sunRadiance: sun.radiance,
                    inverseView: inverseView, inverseProjection: viewUniform.projectionMatrix.inverse,
                    cameraAltitude: inverseView.origin.y
                ),
                view: source.entityId, device: renderDevice
            )
            let time = clouds.time ?? Float(Time.absolute)
            let marchConstants = cloudViews.marchUniform.write(
                Clouds3DUniform(
                    clouds: clouds, tier: tier, time: time, frame: frame.frameIndex, reset: frame.reset,
                    previousViewProjection: frame.previousViewProjection
                ),
                view: source.entityId, device: renderDevice
            )
            let resolveConstants = cloudViews.resolveUniform.write(
                CloudResolveUniform(clouds: clouds, reset: frame.reset, previousViewProjection: frame.previousViewProjection),
                view: source.entityId, device: renderDevice
            )
            let command = renderContext.commandQueue.makeCommandBuffer()
            command.label = "Clouds 3D"
            if buildsNoise {
                cloudViews.noisePipelines.encode(seed: clouds.seed, into: noiseTextures, command: command, device: renderDevice)
            }
            let white = Texture2D.whiteTexture
            func draw(_ label: String, into output: RenderTexture, pipeline: RenderPipeline, bindings: [RenderResourceSet.Binding]) {
                let pass = command.beginRenderPass(RenderPassDescriptor(
                    label: label,
                    colorAttachments: [.init(texture: output, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .black)],
                    depthStencilAttachment: nil
                ))
                pass.setViewport(Rect(x: 0, y: 0, width: Float(output.size.width), height: Float(output.size.height)))
                pass.setRenderPipelineState(pipeline)
                pass.setFragmentBuffer(atmosphereConstants, offset: 0, slot: 4)
                pass.setFragmentBuffer(marchConstants, offset: 0, slot: 5)
                pass.setResourceSet(RenderResourceSet(bindings: bindings), index: 0)
                pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
                pass.endRenderPass()
            }
            let sampler = cloudViews.sampler
            draw(tier.isLayer ? "Clouds Layer" : "Clouds March", into: frame.current, pipeline: tier.isLayer ? cloudViews.layerPipeline : cloudViews.marchPipeline, bindings: [
                .init(binding: 0, shaderStages: .fragment, resource: .texture(tables.transmittance)),
                .init(binding: 1, shaderStages: .fragment, resource: .texture(tables.multiScatter)),
                .init(binding: 2, shaderStages: .fragment, resource: .sampler(sampler)),
                .init(binding: 6, shaderStages: .fragment, resource: .texture(noiseTextures.shape)),
                .init(binding: 7, shaderStages: .fragment, resource: .texture(noiseTextures.detail)),
                .init(binding: 8, shaderStages: .fragment, resource: .texture(noiseTextures.weather)),
                .init(binding: 11, shaderStages: .fragment, resource: .texture(tables.skyView)),
                .init(binding: 12, shaderStages: .fragment, resource: .texture(tables.aerial)),
                .init(binding: 13, shaderStages: .fragment, resource: .texture(tables.aerialTransmittance)),
            ])
            // The resolve pass reads its own uniform in slot 5, so it is drawn with that buffer bound there.
            let resolvePass = command.beginRenderPass(RenderPassDescriptor(
                label: "Clouds Resolve",
                colorAttachments: [frame.write, frame.output].map {
                    .init(texture: $0, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .black)
                },
                depthStencilAttachment: nil
            ))
            resolvePass.setViewport(Rect(x: 0, y: 0, width: Float(frame.write.size.width), height: Float(frame.write.size.height)))
            resolvePass.setRenderPipelineState(cloudViews.resolvePipeline)
            resolvePass.setFragmentBuffer(atmosphereConstants, offset: 0, slot: 4)
            resolvePass.setFragmentBuffer(resolveConstants, offset: 0, slot: 5)
            resolvePass.setResourceSet(RenderResourceSet(bindings: [
                .init(binding: 2, shaderStages: .fragment, resource: .sampler(sampler)),
                .init(binding: 6, shaderStages: .fragment, resource: .texture(frame.current)),
                .init(binding: 7, shaderStages: .fragment, resource: .texture(frame.reset ? white : frame.read)),
            ]), index: 0)
            resolvePass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            resolvePass.endRenderPass()
            if let metrics {
                command.addCompletedTimingHandler { metrics.record(pass: "clouds", seconds: $0) }
                metrics.record(memory: "clouds", bytes: cloudViews.memoryBytes)
            }
            submitted = command
        }
        if let submitted {
            if let metrics { await metrics.commit(submitted) } else { submitted.commit() }
        }
        return []
    }
}
