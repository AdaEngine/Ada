import AdaAssets
import AdaECS
import AdaRender
import AdaUtils
import Math

/// Relights static world-space probe paths using current local lights and their full light-volume shadow atlas.
public struct DynamicIrradiance3DRenderNode: RenderNode {
    public static let name: RenderNodeLabel = "Main3D.DynamicIrradiance"
    @Query<Entity, ExtractedCameraSource> private var views
    @Res<ExtractedEnvironment3D> private var environments
    @ResMut<DynamicIrradiance3DViews> private var resources
    @ResMut<LocalLighting3DGPUScratch> private var localUniforms
    @Res<Render3DDynamicGIStatistics> private var statistics
    @Res<RenderDeviceHandler> private var device
    @Res<Render3DPerformanceMetrics?> private var metrics
    public init() {}
    public func update(from world: World) {
        views.update(from: world); _environments.update(from: world); _resources.update(from: world)
        _localUniforms.update(from: world); _statistics.update(from: world); _device.update(from: world); _metrics.update(from: world)
        var active: [Entity.ID] = []
        views.forEach { _, source in active.append(source.entityId) }
        for id in resources.entries.keys where !active.contains(id) { resources.entries.removeValue(forKey: id) }
        resources.uniforms.retainViews(active); statistics.retain(active)
    }
    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity else { return [] }
        var submitted: CommandBuffer?
        views.forEach { entity, source in
            guard entity == view else { return }
            guard let settings = environments.environments[source.entityId]?.irradianceProbes,
                let dynamic = settings.dynamic, let grid = settings.asset.asset, let cache = dynamic.transport.asset,
                cache.matches(grid) else {
                resources.entries.removeValue(forKey: source.entityId)
                statistics.discard(view: source.entityId)
                return
            }
            let count = cache.counts.reduce(1, *)
            let budget = min(max(dynamic.probesPerFrame, 1), count)
            let size = grid.coefficients.size
            let identity = ObjectIdentifier(cache.positions)
            var entry = resources.entries.removeValue(forKey: source.entityId)
            if entry?.identity != identity {
                entry = .init(identity: identity, pair: (0..<2).map { _ in
                    RenderTexture(size: size, scaleFactor: 1, format: .rgba_16f, debugLabel: "Dynamic probe SH")
                })
            }
            guard var state = entry else { return }
            var shadows = context.world.getResource(LocalShadow3DViews.self)?.entries[source.entityId]
            // Missing shadow slots fail closed. Indirect injection must not illuminate through unseen walls.
            let slots = shadows?.allocator.slots ?? [:]
            shadows?.lights.removeAll { $0.indirectIntensity <= 0 || slots[$0.entity] == nil }
            let lights = shadows?.lights.count ?? 0
            let lightConstants = localUniforms.write(view: source.entityId, pass: 20, count: 135, device: device.renderDevice) {
                packLocalLighting(ExtractedLighting3D(), view: .identity, shadows: shadows, into: &$0)
                for (i, light) in (shadows?.lights ?? []).enumerated() { $0[8+i*4].w *= light.indirectIntensity }
            }
            let matrices = localUniforms.write(view: source.entityId, pass: 21, count: 97, device: device.renderDevice) {
                packLocalShadowMatrices(shadows, into: &$0)
            }
            let constants = resources.uniforms.write(DynamicIrradiance3DUniform(
                grid: [Float(cache.counts[0]),Float(cache.counts[1]),Float(cache.counts[2]),Float(cache.samples)],
                update: [Float(state.cursor),Float(budget),state.initialized ? 0 : 1,Float(lights)],
                blend: [finiteRenderValue(dynamic.historyWeight, fallback: 0.15, range: 0...0.95),
                    finiteRenderValue(dynamic.intensity, fallback: 1, range: 0...4),0,0]),
                view: source.entityId, device: device.renderDevice)
            let pipeline = resources.getPipeline(device.renderDevice)
            guard let nearest = resources.nearest else { return }
            let previous = state.output
            state.index = 1-state.index
            let command = renderContext.commandQueue.makeCommandBuffer()
            command.label = "World probe relighting"
            let pass = command.beginRenderPass(.init(label: "World probe SH update", colorAttachments: [
                .init(texture: state.output, operation: .init(loadAction: .clear, storeAction: .store))]))
            pass.setViewport(Rect(x:0,y:0,width:Float(size.width),height:Float(size.height)))
            pass.setRenderPipelineState(pipeline)
            pass.setFragmentBuffer(constants, offset:0, slot:4)
            pass.setFragmentBuffer(lightConstants, offset:0, slot:25)
            pass.setFragmentBuffer(matrices, offset:0, slot:28)
            pass.setResourceSet(.init(bindings: [
                .init(binding:0,shaderStages:.fragment,resource:.texture(cache.positions)),
                .init(binding:1,shaderStages:.fragment,resource:.texture(cache.normals)),
                .init(binding:2,shaderStages:.fragment,resource:.texture(cache.albedo)),
                .init(binding:3,shaderStages:.fragment,resource:.texture(previous)),
                .init(binding:5,shaderStages:.fragment,resource:.sampler(nearest)),
                .init(binding:6,shaderStages:.fragment,resource:.texture(grid.coefficients)),
                .init(binding:26,shaderStages:.fragment,resource:.texture(shadows?.color ?? Texture2D.whiteTexture))
            ]),index:0)
            pass.draw(type:.triangle,vertexStart:0,vertexCount:3,instanceCount:1); pass.endRenderPass()
            let wrapped = state.cursor+budget >= count
            state.cursor = (state.cursor+budget)%count; state.initialized = true
            resources.entries[source.entityId] = state
            statistics.record(view:source.entityId,count:count,updated:lights == 0 ? count : budget,lights:lights,wrapped:wrapped)
            if let metrics { command.addCompletedTimingHandler { metrics.record(pass:"dynamicGI",seconds:$0) } }
            submitted = command
        }
        if let submitted { if let metrics { await metrics.commit(submitted) } else { submitted.commit() } }
        return []
    }
}
