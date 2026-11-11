import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

struct LocalShadow3DScratch: Resource {
    var cache = FrameUniformCache3D<DirectionalShadowViewUniform>()
    var gpuCull = GPUShadowCull3D()
}

struct LocalShadow3DPipeline: RenderPipelineConfigurator {
    typealias Configuration = Shadow3DConfiguration

    private let base = DirectionalShadow3DPipeline()
    func configurate(with configuration: Shadow3DConfiguration) -> RenderPipelineDescriptor {
        var descriptor = base.configurate(with: configuration)
        descriptor.debugName = "Local Shadow 3D"
        descriptor.colorAttachments = [.init(format: .r32f)]
        return descriptor
    }
}

/// Resets one atlas tile to the far value, so a face can be redrawn while its neighbors keep their contents.
struct LocalShadow3DClear: Resource {
    let pipeline: RenderPipeline

    init(device: RenderDevice) {
        let shader = CorePipelineShaders.loadRequiredBundled(at: "Shaders/shadow_clear_3d.glsl")
        var descriptor = RenderPipelineDescriptor(
            vertex: shader.asset.requiredShader(for: .vertex),
            fragment: shader.asset.getShader(for: .fragment),
            debugName: "Local Shadow Clear 3D",
            backfaceCulling: false
        )
        descriptor.depthStencilDescriptor = DepthStencilDescriptor(isDepthTestEnabled: false, isDepthWriteEnabled: false, depthCompareOperator: .always)
        descriptor.colorAttachments = [.init(format: .r32f)]
        pipeline = device.createRenderPipeline(from: descriptor)
    }
}

/// One atlas pass per camera covers a bounded set of point/spot shadow faces, including offscreen casters.
public struct LocalShadow3DRenderNode: RenderNode {
    public static let name: RenderNodeLabel = "Main3D.LocalShadows"
    @Query<Entity, Camera, GlobalViewUniform, ExtractedCameraSource> private var cameras
    @Res<ExtractedLighting3D> private var lighting
    @Res<Render3DLightStatistics> private var statistics
    @Res<ExtractedEnvironment3D> private var environments
    @ResMut<LocalShadow3DViews> private var views
    @ResMut<LocalShadow3DScratch> private var scratch
    @ResMut<LocalLighting3DGPUScratch> private var uniforms
    @ResMut<VisibleMesh3DLists> private var lists
    @ResMut<ShadowCasterRegistry3D> private var registry
    @ResMut<PBR3DUniforms> private var materials
    @Res<Skinning3DUniforms> private var skinning
    @ResMut<RenderPipelines<LocalShadow3DPipeline>> private var pipelines
    @Res<RenderDeviceHandler> private var device
    @Res<LocalShadow3DClear> private var clear
    @Res<Render3DPerformanceMetrics?> private var metrics

    public init() {}

    public func update(from world: World) {
        cameras.update(from: world)
        _lighting.update(from: world)
        _environments.update(from: world)
        _statistics.update(from: world)
        _views.update(from: world)
        _scratch.update(from: world)
        _uniforms.update(from: world)
        _lists.update(from: world)
        _registry.update(from: world)
        _materials.update(from: world)
        _skinning.update(from: world)
        _pipelines.update(from: world)
        _device.update(from: world)
        _clear.update(from: world)
        _metrics.update(from: world)
        let active: [Entity.ID]
        if let targets = world.getResource(ExtractedCameraRenderViewTargets.self) {
            // Proxy entities and their uniforms may be absent while the source camera is backpressured.
            // Only authoritative camera removal should retire its atlas and reusable face contents.
            active = Array(targets.activeCameraIDs)
        } else {
            var extracted: [Entity.ID] = []
            cameras.forEach { _, _, _, source in extracted.append(source.entityId) }
            active = extracted
        }
        for id in views.entries.keys where !active.contains(id) { views.entries.removeValue(forKey: id) }
        scratch.cache.retainViews(active)
        scratch.gpuCull.retainViews(active)
        statistics.retainViews(active)
        uniforms.retainViews(active)
    }

    /// Rebuilds the CPU lists of `faces` from every caster, for a frame whose GPU culling could not be encoded.
    private func prepareCPUFallback(
        faces: [Int],
        sources: [Mesh3DRenderSource],
        camera: Entity.ID,
        uniform: GlobalViewUniform,
        matrices: [Transform3D],
        lod: Bool
    ) {
        for index in faces {
            lists.prepare(
                sources: sources,
                view: camera,
                pass: 100 + index,
                viewMatrix: uniform.viewMatrix,
                projection: uniform.projectionMatrix,
                cullingProjection: matrices[index],
                settings: MeshVisibilitySettings3D(frustumCulling: true, lod: lod, distanceCulling: false),
                device: device.renderDevice,
                materials: &_materials.wrappedValue
            )
        }
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity,
            let candidates = context.world.getResource(ExtractedMesh3DSources.self) else {
            return []
        }
        var submitted: CommandBuffer?
        cameras.forEach { entity, _, uniform, source in
            guard entity == view else {
                return
            }
            var entry = views.entries.removeValue(forKey: source.entityId) ?? LocalShadow3DViews.Entry()
            let viewStart = PerformanceStallProbe.begin()
            defer {
                if let viewStart {
                    PerformanceStallProbe.end("LocalShadow.View.reused\(entry.reusedFaces)", since: viewStart, count: entry.renderedFaces)
                }
            }
            let environment = environments.environments[source.entityId] ?? Environment3D()
            let cameraPosition = uniform.viewMatrix.inverse.origin
            let probes = environment.irradianceProbes
            let grid = probes?.asset.asset
            let transport = probes?.dynamic?.transport.asset
            var bounds: AABB?
            if let grid, transport?.matches(grid) == true {
                // A light may illuminate a bounce wall outside the receiver grid itself.
                bounds = transport?.surfaceBounds
            }
            let selectStart = PerformanceStallProbe.begin()
            entry.lights = LocalLighting3DMath.select(lighting.localLights, viewProjection: uniform.viewProjectionMatrix,
                cameraPosition: cameraPosition, irradianceBounds: bounds)
            let settings = environment.localShadows
            let budget = settings.isEnabled ? min(max(settings.maximumLights, 0), LocalLighting3DMath.maximumShadowLights) : 0
            entry.allocator.select(entry.lights, cameraPosition: cameraPosition, budget: budget)
            PerformanceStallProbe.end("LocalShadow.Select", since: selectStart, count: entry.allocator.slots.count)
            for index in entry.matrices.indices { entry.matrices[index] = .identity }
            guard !entry.allocator.slots.isEmpty, !candidates.meshes.isEmpty else {
                // A light without shadow resources still contributes full unshadowed PBR lighting.
                entry.allocator.select([], cameraPosition: cameraPosition, budget: 0)
                statistics.record(view: source.entityId, scene: _lighting.wrappedValue, entry: entry)
                views.entries[source.entityId] = entry
                return
            }
            let resolution = settings.sanitizedResolution
            let size = SizeInt(width: resolution * 6, height: resolution * budget)
            if entry.color?.size != size {
                let atlasStart = PerformanceStallProbe.begin()
                defer { PerformanceStallProbe.end("LocalShadow.AtlasAllocate", since: atlasStart, bytes: size.width * size.height * 12, count: resolution) }
                entry.color = RenderTexture(
                    size: size,
                    scaleFactor: 1,
                    format: .r32f,
                    debugLabel: "Local Shadow Atlas",
                    samplerDescription: .init(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped)
                )
                entry.depth = RenderTexture(size: size, scaleFactor: 1, format: .depth_32f_stencil8, debugLabel: "Local Shadow Depth")
                // A new atlas holds nothing worth keeping.
                entry.faceDigests.removeAll()
                entry.faceMatrixDigests.removeAll()
                entry.sceneDigest = nil
            }
            guard let color = entry.color, let depth = entry.depth else {
                views.entries[source.entityId] = entry
                return
            }

            // Prepare every face and fingerprint it before encoding, so unchanged faces can be left alone.
            struct Face {
                var index: Int
                var tile: Rect
                var isClean: Bool
            }
            var faces: [Face] = []
            var digests: [Int: UInt64] = [:]
            var matrixDigests: [Int: UInt64] = [:]
            // With the casters unchanged since the faces were last prepared, a face whose matrix is also unchanged
            // draws what it drew before, so its list needs no rebuilding at all.
            let digestStart = PerformanceStallProbe.begin()
            let sceneDigest = settings.reusesStaticFaces
                ? ShadowSceneDigest3D.compute(sources: candidates.meshes, usesLOD: environment.meshVisibility.lod)
                : nil
            PerformanceStallProbe.end("LocalShadow.SceneDigest", since: digestStart, count: candidates.meshes.count)
            let sceneUnchanged = sceneDigest != nil && sceneDigest == entry.sceneDigest
            // Static casters are culled for every redrawn face in one GPU pass; the rest keep the CPU lists.
            registry.update(
                sources: candidates.meshes,
                materials: &_materials.wrappedValue,
                identityPalette: skinning.identityBuffer,
                device: device.renderDevice,
                transformChanges: candidates.transformChanges
            )
            let usesGPU = scratch.gpuCull.isAvailable(
                camera: source.entityId,
                registry: registry,
                viewCount: entry.allocator.slots.count * 6,
                device: device.renderDevice
            )
            let cpuSources = usesGPU ? registry.cpuSources : candidates.meshes
            // Faces kept from earlier frames must also hold the current GPU-path casters.
            let registryRevision: UInt64? = usesGPU ? registry.revision : nil
            let registryChanges: [AABB]?
            if registryRevision == entry.registryRevision {
                registryChanges = []
            } else if let previous = entry.registryRevision, let current = registryRevision, current == previous &+ 1 {
                registryChanges = registry.changedBounds
            } else {
                registryChanges = nil
            }
            // A face is dirtied by a GPU-path caster that was, or now is, inside it (the CPU frustum test).
            func registryDirties(_ matrix: Transform3D) -> Bool {
                guard let registryChanges else { return true }
                guard !registryChanges.isEmpty else { return false }
                let frustum = MeshVisibilityFrustum3D(viewProjection: matrix)
                return registryChanges.contains { frustum.intersects($0) }
            }
            let prepareStart = PerformanceStallProbe.begin()
            var preparedFaceCount = 0
            var culledFaceCount = 0
            let viewFrustum = MeshVisibilityFrustum3D(viewProjection: uniform.viewProjectionMatrix)
            for light in entry.lights {
                guard let slot = entry.allocator.slots[light.entity] else { continue }
                let matrices = LocalLighting3DMath.shadowProjections(light)
                for face in matrices.indices {
                    let index = slot * 6 + face
                    entry.matrices[index] = matrices[face]
                    let tile = Rect(x: Float(face * resolution), y: Float(slot * resolution), width: Float(resolution), height: Float(resolution))
                    var matrixDigest = FrameDigest3D()
                    matrixDigest.combine(matrices[face])
                    matrixDigests[index] = matrixDigest.value
                    // A moving light changes every face matrix each frame. Faces nothing on screen (or lit by
                    // dynamic irradiance) can sample are skipped; without a digest they redraw once they matter.
                    let faceBounds = LocalLighting3DMath.shadowFaceBounds(light, face: face)
                    guard LocalLighting3DMath.shadowFaceIsSampled(faceBounds, viewFrustum: viewFrustum, irradianceBounds: bounds) else {
                        culledFaceCount += 1
                        continue
                    }
                    if sceneUnchanged, let kept = entry.faceDigests[index], entry.faceMatrixDigests[index] == matrixDigest.value {
                        digests[index] = kept
                        faces.append(Face(index: index, tile: tile, isClean: true))
                        continue
                    }
                    // Light-volume culling is independent of the main camera list and its distance cuts.
                    let listStart = PerformanceStallProbe.begin()
                    lists.prepare(
                        sources: cpuSources,
                        view: source.entityId,
                        pass: 100 + index,
                        viewMatrix: uniform.viewMatrix,
                        projection: uniform.projectionMatrix,
                        cullingProjection: matrices[face],
                        settings: MeshVisibilitySettings3D(frustumCulling: true, lod: environment.meshVisibility.lod, distanceCulling: false),
                        device: device.renderDevice,
                        materials: &_materials.wrappedValue
                    )
                    preparedFaceCount += 1
                    if let listStart {
                        PerformanceStallProbe.end("LocalShadow.ListsPrepare.face\(index)", since: listStart,
                            count: lists.count(view: source.entityId, pass: 100 + index).drawCalls)
                    }
                    var digest: UInt64?
                    if settings.reusesStaticFaces, let content = lists.shadowDigest(view: source.entityId, pass: 100 + index) {
                        var combined = FrameDigest3D()
                        combined.combine(matrices[face])
                        combined.combine(content)
                        digest = combined.value
                        digests[index] = combined.value
                    }
                    let isClean = digest != nil && entry.faceDigests[index] == digest && !registryDirties(matrices[face])
                    faces.append(Face(index: index, tile: tile, isClean: isClean))
                }
            }
            PerformanceStallProbe.end("LocalShadow.PrepareFaces", since: prepareStart, count: preparedFaceCount)
            entry.sceneDigest = sceneDigest
            entry.registryRevision = registryRevision
            entry.faceMatrixDigests = matrixDigests
            entry.faceDigests = digests
            entry.reusedFaces = faces.filter(\.isClean).count
            entry.renderedFaces = faces.count - entry.reusedFaces
            entry.culledFaces = culledFaceCount
            guard entry.renderedFaces > 0 else {
                // Every face already holds what it would draw again.
                statistics.record(view: source.entityId, scene: _lighting.wrappedValue, entry: entry)
                views.entries[source.entityId] = entry
                return
            }

            let keepsContents = entry.reusedFaces > 0
            let command = renderContext.commandQueue.makeCommandBuffer()
            command.label = "Local Shadows 3D"
            let dirtyFaces = faces.filter { !$0.isClean }
            registry.flushCopies(on: command)
            var culled: GPUShadowCullResult?
            if usesGPU {
                culled = scratch.gpuCull.cull(
                    camera: source.entityId,
                    registry: &_registry.wrappedValue,
                    views: dirtyFaces.map { GPUShadowCullView(viewProjection: entry.matrices[$0.index], culls: true) },
                    command: command,
                    device: device.renderDevice
                )
                if culled == nil {
                    // The GPU pass could not be encoded: draw every caster from CPU lists instead.
                    prepareCPUFallback(
                        faces: dirtyFaces.map(\.index), sources: candidates.meshes, camera: source.entityId,
                        uniform: uniform, matrices: entry.matrices, lod: environment.meshVisibility.lod
                    )
                    entry.registryRevision = nil
                }
            }
            let beginPassStart = PerformanceStallProbe.begin()
            let pass = command.beginRenderPass(
                .init(
                    label: "Local Shadows 3D",
                    colorAttachments: [.init(texture: color, operation: .init(loadAction: keepsContents ? .load : .clear, storeAction: .store), clearColor: .white)],
                    depthStencilAttachment: .init(
                        texture: depth,
                        depthOperation: .init(loadAction: .clear, storeAction: .dontCare),
                        stencilOperation: .init(loadAction: .clear, storeAction: .dontCare)
                    )
                )
            )
            PerformanceStallProbe.end("LocalShadow.BeginPass", since: beginPassStart, count: entry.renderedFaces)
            let encodeStart = PerformanceStallProbe.begin()
            var encodedDrawCount = 0
            // Faces of one light, and of all lights, draw the same batches: resolve their state once.
            var batches = ShadowBatchEncoder3D(requiresMaterialBuffer: true)
            for (viewIndex, face) in dirtyFaces.enumerated() {
                let index = face.index
                let tile = face.tile
                pass.setViewport(tile)
                pass.setScissorRect(tile)
                if keepsContents {
                    pass.setRenderPipelineState(clear.pipeline)
                    pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
                }
                let buffers = lists.buffers(view: source.entityId, pass: 100 + index)
                let constants = scratch.cache.write(
                    DirectionalShadowViewUniform(viewProjection: entry.matrices[index], tileBounds: [tile.minX, tile.minY, tile.maxX, tile.maxY]),
                    view: source.entityId,
                    pass: index,
                    device: device.renderDevice
                )
                pass.setVertexBuffer(constants, offset: 0, slot: GlobalBufferIndex.viewUniform)
                if let instances = buffers.instances {
                    encodedDrawCount += batches.encode(
                        items: lists.items(view: source.entityId, pass: 100 + index),
                        instances: instances,
                        defaults: buffers.defaults,
                        pass: pass,
                        pipelines: &_pipelines.wrappedValue,
                        materials: materials,
                        identityPalette: skinning.identityBuffer,
                        device: device.renderDevice
                    )
                }
                if let culled {
                    encodedDrawCount += GPUShadowCull3D.draw(
                        registry: registry,
                        output: culled,
                        view: viewIndex,
                        pass: pass,
                        pipelines: &_pipelines.wrappedValue,
                        device: device.renderDevice
                    )
                }
            }
            pass.endRenderPass()
            PerformanceStallProbe.end("LocalShadow.EncodeDraws", since: encodeStart, count: encodedDrawCount)
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
