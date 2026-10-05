import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

struct LocalShadow3DScratch: Resource {
    var cache = FrameUniformCache3D<DirectionalShadowViewUniform>()
}

struct LocalShadow3DPipeline: RenderPipelineConfigurator {
    private let base = DirectionalShadow3DPipeline()
    func configurate(with configuration: VertexDescriptor) -> RenderPipelineDescriptor {
        var descriptor = base.configurate(with: configuration)
        descriptor.debugName = "Local Shadow 3D"
        descriptor.colorAttachments = [.init(format: .rgba_16f)]
        return descriptor
    }
}

/// One atlas pass per camera covers a bounded set of point/spot shadow faces, including offscreen casters.
public struct LocalShadow3DRenderNode: RenderNode {
    public static let name: RenderNodeLabel = "Main3D.LocalShadows"
    @Query<Entity, Camera, GlobalViewUniform, ExtractedCameraSource> private var cameras
    @Res<ExtractedLighting3D> private var lighting
    @Res<Render3DLightStatistics> private var statistics
    @Res<ExtractedEnvironment3D> private var environments
    @Res<ExtractedMesh3DSources> private var candidates
    @ResMut<LocalShadow3DViews> private var views
    @ResMut<LocalShadow3DScratch> private var scratch
    @ResMut<LocalLighting3DGPUScratch> private var uniforms
    @ResMut<VisibleMesh3DLists> private var lists
    @ResMut<PBR3DUniforms> private var materials
    @Res<Skinning3DUniforms> private var skinning
    @ResMut<RenderPipelines<LocalShadow3DPipeline>> private var pipelines
    @Res<RenderDeviceHandler> private var device
    @Res<Render3DPerformanceMetrics?> private var metrics

    public init() {}

    public func update(from world: World) {
        cameras.update(from: world)
        _lighting.update(from: world)
        _environments.update(from: world)
        _statistics.update(from: world)
        _candidates.update(from: world)
        _views.update(from: world)
        _scratch.update(from: world)
        _uniforms.update(from: world)
        _lists.update(from: world)
        _materials.update(from: world)
        _skinning.update(from: world)
        _pipelines.update(from: world)
        _device.update(from: world)
        _metrics.update(from: world)
        var active: [Entity.ID] = []
        cameras.forEach { _, _, _, source in active.append(source.entityId) }
        for id in views.entries.keys where !active.contains(id) { views.entries.removeValue(forKey: id) }
        scratch.cache.retainViews(active)
        statistics.retainViews(active)
        uniforms.retainViews(active)
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity else {
            return []
        }
        var submitted: CommandBuffer?
        cameras.forEach { entity, _, uniform, source in
            guard entity == view else {
                return
            }
            var entry = views.entries.removeValue(forKey: source.entityId) ?? LocalShadow3DViews.Entry()
            let environment = environments.environments[source.entityId] ?? Environment3D()
            let cameraPosition = uniform.viewMatrix.inverse.origin
            entry.lights = LocalLighting3DMath.select(lighting.localLights, viewProjection: uniform.viewProjectionMatrix, cameraPosition: cameraPosition)
            let settings = environment.localShadows
            let budget = settings.isEnabled ? min(max(settings.maximumLights, 0), LocalLighting3DMath.maximumShadowLights) : 0
            entry.allocator.select(entry.lights, cameraPosition: cameraPosition, budget: budget)
            for index in entry.matrices.indices { entry.matrices[index] = .identity }
            guard !entry.allocator.slots.isEmpty, !candidates.meshes.isEmpty else {
                // A light without shadow resources still contributes full unshadowed PBR lighting.
                entry.allocator.select([], cameraPosition: cameraPosition, budget: 0)
                statistics.record(view: source.entityId, scene: _lighting.wrappedValue, entry: entry)
                views.entries[source.entityId] = entry
                return
            }
            let resolution = LocalLighting3DMath.shadowResolution
            let size = SizeInt(width: resolution * 6, height: resolution * budget)
            if entry.color?.size != size {
                entry.color = RenderTexture(
                    size: size,
                    scaleFactor: 1,
                    format: .rgba_16f,
                    debugLabel: "Local Shadow Atlas",
                    samplerDescription: .init(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped)
                )
                entry.depth = RenderTexture(size: size, scaleFactor: 1, format: .depth_32f_stencil8, debugLabel: "Local Shadow Depth")
            }
            guard let color = entry.color, let depth = entry.depth else {
                views.entries[source.entityId] = entry
                return
            }
            let command = renderContext.commandQueue.makeCommandBuffer()
            command.label = "Local Shadows 3D"
            let pass = command.beginRenderPass(
                .init(
                    label: "Local Shadows 3D",
                    colorAttachments: [.init(texture: color, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .white)],
                    depthStencilAttachment: .init(
                        texture: depth,
                        depthOperation: .init(loadAction: .clear, storeAction: .dontCare),
                        stencilOperation: .init(loadAction: .clear, storeAction: .dontCare)
                    )
                )
            )
            for light in entry.lights {
                guard let slot = entry.allocator.slots[light.entity] else { continue }
                let matrices = LocalLighting3DMath.shadowProjections(light)
                for face in matrices.indices {
                    let index = slot * 6 + face
                    entry.matrices[index] = matrices[face]
                    let tile = Rect(x: Float(face * resolution), y: Float(slot * resolution), width: Float(resolution), height: Float(resolution))
                    pass.setViewport(tile)
                    pass.setScissorRect(tile)
                    // Light-volume culling is independent of the main camera list and its distance cuts.
                    lists.prepare(
                        sources: candidates.meshes,
                        view: source.entityId,
                        pass: 100 + index,
                        viewMatrix: uniform.viewMatrix,
                        projection: uniform.projectionMatrix,
                        cullingProjection: matrices[face],
                        settings: MeshVisibilitySettings3D(frustumCulling: true, lod: environment.meshVisibility.lod, distanceCulling: false),
                        device: device.renderDevice,
                        materials: &_materials.wrappedValue
                    )
                    let buffers = lists.buffers(view: source.entityId, pass: 100 + index)
                    guard let instances = buffers.instances else { continue }
                    let constants = scratch.cache.write(
                        DirectionalShadowViewUniform(viewProjection: matrices[face], tileBounds: [tile.minX, tile.minY, tile.maxX, tile.maxY]),
                        view: source.entityId,
                        pass: index,
                        device: device.renderDevice
                    )
                    pass.setVertexBuffer(constants, offset: 0, slot: GlobalBufferIndex.viewUniform)
                    for item in lists.items(view: source.entityId, pass: 100 + index) {
                        guard item.castShadows, let range = item.batchRange, (item.material as? PBRMaterial)?.alphaMode != .blend else { continue }
                        let part = item.mesh.models[item.modelIndex].parts[item.partIndex]
                        guard let material = materials.buffer(for: item.material), let palette = item.skinningBuffer ?? skinning.identityBuffer else { continue }
                        pass.setRenderPipelineState(pipelines.pipeline(for: part.vertexDescriptor, device: device.renderDevice))
                        pass.setVertexBuffer(part.vertexBuffer, offset: 0, slot: 0)
                        pass.setVertexBuffer(instances, offset: Int(range.lowerBound) * MemoryLayout<Flat3DInstanceData>.stride, slot: 3)
                        if let defaults = buffers.defaults { pass.setVertexBuffer(defaults, offset: 0, slot: 4) }
                        let base = (item.material as? PBRMaterial)?.baseColorTexture ?? Texture2D.whiteTexture
                        pass.setResourceSet(
                            .init(bindings: [
                                .init(binding: 15, shaderStages: .fragment, resource: .uniformBuffer(material, offset: 0)),
                                .init(binding: 4, shaderStages: .fragment, resource: .texture(base)),
                                .init(binding: 7, shaderStages: .fragment, resource: .sampler(base.sampler)),
                                .init(binding: Skinning3DUniforms.binding, shaderStages: .vertex, resource: .uniformBuffer(palette, offset: 0)),
                            ]),
                            index: 0
                        )
                        pass.setIndexBuffer(part.indexBuffer, offset: 0)
                        pass.drawIndexed(indexCount: part.indexCount, indexBufferOffset: 0, instanceCount: Int(range.count))
                    }
                }
            }
            pass.endRenderPass()
            if let metrics { command.addCompletedTimingHandler { metrics.record(pass: "local-shadows", seconds: $0) } }
            submitted = command
            statistics.record(view: source.entityId, scene: _lighting.wrappedValue, entry: entry)
            views.entries[source.entityId] = entry
        }
        if let submitted {
            if let metrics { await metrics.commit(submitted) } else { submitted.commit() }
        }
        return []
    }
}
