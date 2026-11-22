import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math
import Synchronization

/// Render-world marker installed only by Studio's Metal edit preview.
struct StudioShadowCache: Resource {}

struct ShadowCasterLayers3D {
    var staticCasters: [Mesh3DRenderSource] = []
    var movingCasters: [Mesh3DRenderSource] = []
    private(set) var staticFingerprint: UInt64 = 0

    init(_ sources: [Mesh3DRenderSource]) {
        for source in sources where source.castShadows {
            if Self.hasTrackedStaticGeometry(source) {
                staticCasters.append(source)
            } else {
                movingCasters.append(source)
            }
        }
        var fingerprint = FrameDigest3D()
        fingerprint.combine(ShadowSceneDigest3D.compute(sources: staticCasters, usesLOD: false) ?? 0)
        for source in staticCasters {
            fingerprint.combine(UInt64(bitPattern: Int64(source.entity.hashValue)))
            fingerprint.combine(source.maximumDistance ?? 0)
            fingerprint.combine(source.fadeDistance)
            fingerprint.combine(source.hysteresis)
            if let bounds = source.bounds {
                fingerprint.combine(Vector4(bounds.min.x, bounds.min.y, bounds.min.z, 1))
                fingerprint.combine(Vector4(bounds.max.x, bounds.max.y, bounds.max.z, 1))
            } else {
                fingerprint.combine(UInt64(0))
            }
            fingerprint.combine(UInt64(source.thresholds.count))
            for threshold in source.thresholds { fingerprint.combine(threshold) }
            for mesh in [source.mesh] + source.alternatives {
                for model in mesh.models {
                    for part in model.parts {
                        fingerprint.combine(UInt64(bitPattern: Int64(part.vertexDescriptor.hashValue)))
                        fingerprint.combine(UInt64(UInt(bitPattern: ObjectIdentifier(part.vertexBuffer))))
                        fingerprint.combine(UInt64(UInt(bitPattern: ObjectIdentifier(part.indexBuffer))))
                        fingerprint.combine(part.vertexBuffer.shadowRasterRevision ?? 0)
                        fingerprint.combine(part.indexBuffer.shadowRasterRevision ?? 0)
                        fingerprint.combine(UInt64(part.indexCount))
                    }
                }
            }
        }
        staticFingerprint = fingerprint.value
    }

    func preparationKey(
        uniform: GlobalViewUniform,
        lightProjection: Transform3D,
        settings: MeshVisibilitySettings3D
    ) -> UInt64 {
        var digest = FrameDigest3D()
        digest.combine(staticFingerprint)
        digest.combine(lightProjection)
        digest.combine(settings.frustumCulling ? UInt64(1) : 0)
        digest.combine(settings.lod ? UInt64(1) : 0)
        digest.combine(settings.distanceCulling ? UInt64(1) : 0)
        if settings.lod || settings.distanceCulling {
            digest.combine(uniform.viewMatrix)
            digest.combine(uniform.projectionMatrix)
        }
        return digest.value
    }

    private static func hasTrackedStaticGeometry(_ source: Mesh3DRenderSource) -> Bool {
        guard source.skinningBuffer == nil, source.morphBuffers.isEmpty,
            source.transform == source.previousTransform,
            source.materials.allSatisfy({ ($0 as? PBRMaterial)?.effectiveAlphaMode == .opaque })
        else {
            return false
        }
        // Alpha masks can depend on texture contents and shader graph time. Keep all of them live.
        return ([source.mesh] + source.alternatives).allSatisfy { mesh in
            mesh.models.allSatisfy { model in
                model.parts.allSatisfy { $0.vertexBuffer.shadowRasterRevision != nil && $0.indexBuffer.shadowRasterRevision != nil }
            }
        }
    }
}

extension VisibleMesh3DLists {
    mutating func prepareShadowCacheLayers(
        _ layers: ShadowCasterLayers3D,
        view: Entity.ID,
        pass: Int,
        uniform: GlobalViewUniform,
        lightProjection: Transform3D,
        settings: MeshVisibilitySettings3D,
        device: RenderDevice,
        materials: inout PBR3DUniforms,
        preparedDigest: UInt64?
    ) -> (digest: UInt64, hasMoving: Bool) {
        let staticDigest: UInt64
        if let preparedDigest {
            staticDigest = preparedDigest
        } else {
            prepare(
                sources: layers.staticCasters,
                view: view,
                pass: pass,
                viewMatrix: uniform.viewMatrix,
                projection: uniform.projectionMatrix,
                cullingProjection: lightProjection,
                settings: settings,
                device: device,
                materials: &materials,
                reconcileMembership: false
            )
            var digest = FrameDigest3D()
            digest.combine(shadowDigest(view: view, pass: pass) ?? 0)
            for item in items(view: view, pass: pass) {
                let part = item.mesh.models[item.modelIndex].parts[item.partIndex]
                digest.combine(UInt64(bitPattern: Int64(part.vertexDescriptor.hashValue)))
            }
            staticDigest = digest.value
        }
        let frustum = MeshVisibilityFrustum3D(viewProjection: lightProjection)
        let mightHaveMovingCasters = layers.movingCasters.contains { source in
            !settings.frustumCulling || source.forceVisible || source.instances != nil
                || (source.bounds.map { frustum.intersects($0) } ?? true)
        }
        guard mightHaveMovingCasters else {
            return (staticDigest, false)
        }
        prepare(
            sources: layers.movingCasters,
            view: view,
            pass: pass + 1,
            viewMatrix: uniform.viewMatrix,
            projection: uniform.projectionMatrix,
            cullingProjection: lightProjection,
            settings: settings,
            device: device,
            materials: &materials,
            reconcileMembership: false
        )
        return (staticDigest, !items(view: view, pass: pass + 1).isEmpty)
    }
}

/// Retains rasterized static depth per tile and produces the existing packed shadow output.
struct ShadowMapCache3D: Sendable {
    struct Tile: Sendable {
        let index: Int
        let rect: Rect
        let projection: Transform3D
        let light: Entity.ID?
        let staticDigest: UInt64
        let preparationKey: UInt64
        let hasMovingCasters: Bool
        let firstList: Int
        let constants: BufferData<DirectionalShadowViewUniform>

        var key: TileKey { TileKey(projection: projection, light: light, digest: staticDigest) }
    }

    struct TileKey: Equatable, Sendable {
        let projection: Transform3D
        let light: Entity.ID?
        let digest: UInt64
    }

    private final class Submission: Sendable {
        private let outcome = Mutex<Bool?>(nil)

        var succeeded: Bool { outcome.withLock { $0 == true } }
        var failed: Bool { outcome.withLock { $0 == false } }

        func finish(_ success: Bool) {
            outcome.withLock { $0 = success }
        }
    }

    private struct State: Sendable {
        let key: TileKey
        var preparationKey: UInt64
        let hadMovingCasters: Bool
        let staticWrite: Submission
        let outputWrite: Submission
    }

    private struct View: Sendable {
        let output: RenderTexture
        let staticDepth: RenderTexture
        var tiles: [Int: State] = [:]
    }

    struct Update {
        let command: (any CommandBuffer)?
        let staticTiles: Int
        let composedTiles: Int
    }

    private var views: [Entity.ID: View] = [:]
    private var outputOwners: [ObjectIdentifier: Entity.ID] = [:]
    private var failedViews: Set<Entity.ID> = []
    private var movingDepth: RenderTexture?
    private var mergePipeline: (any RenderPipeline)?
    private var clearPipeline: (any RenderPipeline)?
    private var pipelineFormat: PixelFormat?
    private(set) var totalStaticTilesDrawn = 0

    mutating func retainViews(_ active: [Entity.ID]) {
        views = views.filter { active.contains($0.key) }
        outputOwners = outputOwners.filter { active.contains($0.value) }
        failedViews.formIntersection(active)
        if active.isEmpty { movingDepth = nil }
    }

    mutating func discard(view: Entity.ID) {
        views.removeValue(forKey: view)
        outputOwners = outputOwners.filter { $0.value != view }
        if views.isEmpty { movingDepth = nil }
    }

    mutating func invalidateOutput(_ output: RenderTexture) {
        outputOwners.removeValue(forKey: ObjectIdentifier(output))
    }

    func preparedDigest(view: Entity.ID, tile: Int, key: UInt64, output: RenderTexture, light: Entity.ID?) -> UInt64? {
        guard let atlas = views[view], atlas.output === output, let state = atlas.tiles[tile],
            state.preparationKey == key, state.key.light == light, state.staticWrite.succeeded
        else { return nil }
        return state.key.digest
    }

    mutating func isUsable(for view: Entity.ID) -> Bool {
        if views[view]?.tiles.values.contains(where: { $0.staticWrite.failed || $0.outputWrite.failed }) == true {
            // Keep this view on the full path until it is recreated.
            failedViews.insert(view)
        }
        return !failedViews.contains(view)
    }

    static func supports(_ texture: RenderTexture) -> Bool {
        let bytesPerPixel: Int
        switch texture.pixelFormat {
        case .r32f: bytesPerPixel = 4
        case .rgba_32f: bytesPerPixel = 16
        default: return false
        }
        // Cache one output-sized color atlas and reuse scratch. Avoid an extra oversized atlas for extreme quality settings.
        return texture.width > 0 && texture.height > 0 && texture.width <= (64 * 1024 * 1024 / bytesPerPixel) / texture.height
    }

    mutating func encode(
        view id: Entity.ID,
        output: RenderTexture,
        depth: RenderTexture,
        tiles: [Tile],
        device: RenderDevice,
        queue: CommandQueue,
        label: String,
        draw: (Tile, Bool, any RenderCommandEncoder) -> Void
    ) -> Update {
        let isNew: Bool
        var view: View
        let cached = views.removeValue(forKey: id)
        if let cached, cached.output === output {
            isNew = false
            view = cached
        } else {
            isNew = true
            if let previous = cached?.output { invalidateOutput(previous) }
            view = View(output: output, staticDepth: makeColor(like: output, label: "Cached Static Shadow Depth"))
        }
        let outputID = ObjectIdentifier(output)
        let outputWasReplaced = outputOwners[outputID] != id
        outputOwners[outputID] = id
        let dirty = tiles.filter { tile in
            let state = view.tiles[tile.index]
            return state?.key != tile.key || state?.staticWrite.succeeded != true
        }
        let dirtyIDs = Set(dirty.map(\.index))
        let moving = tiles.filter(\.hasMovingCasters)
        let composite = tiles.filter { tile in
            let state = view.tiles[tile.index]
            return outputWasReplaced || dirtyIDs.contains(tile.index) || tile.hasMovingCasters
                || state?.hadMovingCasters == true || state?.outputWrite.succeeded != true
        }
        for tile in tiles {
            view.tiles[tile.index]?.preparationKey = tile.preparationKey
        }
        guard !composite.isEmpty else {
            views[id] = view
            return Update(command: nil, staticTiles: 0, composedTiles: 0)
        }
        preparePipelines(format: output.pixelFormat, device: device)
        guard let mergePipeline, let clearPipeline else {
            return Update(command: nil, staticTiles: 0, composedTiles: 0)
        }

        let command = queue.makeCommandBuffer()
        command.label = label
        if !dirty.isEmpty {
            let pass = beginDraw(command: command, color: view.staticDepth, depth: depth, clearColor: isNew, label: "Static Shadow Tiles")
            for tile in dirty {
                pass.setViewport(tile.rect)
                pass.setScissorRect(tile.rect)
                if !isNew {
                    pass.setRenderPipelineState(clearPipeline)
                    pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
                }
                draw(tile, false, pass)
            }
            pass.endRenderPass()
        }
        if !moving.isEmpty {
            if movingDepth?.size != output.size || movingDepth?.pixelFormat != output.pixelFormat {
                movingDepth = makeColor(like: output, label: "Moving Shadow Depth Scratch")
            }
            if let movingDepth {
                let pass = beginDraw(command: command, color: movingDepth, depth: depth, clearColor: true, label: "Moving Shadow Tiles")
                for tile in moving {
                    pass.setViewport(tile.rect)
                    pass.setScissorRect(tile.rect)
                    draw(tile, true, pass)
                }
                pass.endRenderPass()
            }
        }
        let pass = command.beginRenderPass(
            .init(
                label: "Compose Shadow Tiles",
                colorAttachments: [
                    .init(texture: output, operation: .init(loadAction: isNew ? .clear : .load, storeAction: .store), clearColor: .white)
                ]
            )
        )
        pass.setRenderPipelineState(mergePipeline)
        for tile in composite {
            pass.setViewport(tile.rect)
            pass.setScissorRect(tile.rect)
            pass.setFragmentTexture(view.staticDepth, slot: 0)
            pass.setFragmentTexture(tile.hasMovingCasters ? movingDepth ?? view.staticDepth : view.staticDepth, slot: 1)
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
        }
        pass.endRenderPass()
        let submission = Submission()
        for tile in composite {
            let staticWrite = dirtyIDs.contains(tile.index) ? submission : view.tiles[tile.index]?.staticWrite ?? submission
            view.tiles[tile.index] = State(
                key: tile.key,
                preparationKey: tile.preparationKey,
                hadMovingCasters: tile.hasMovingCasters,
                staticWrite: staticWrite,
                outputWrite: submission
            )
        }
        command.observeSubmissionResult { submission.finish($0) }
        views[id] = view
        totalStaticTilesDrawn &+= dirty.count
        return Update(command: command, staticTiles: dirty.count, composedTiles: composite.count)
    }

    private func makeColor(like output: RenderTexture, label: String) -> RenderTexture {
        RenderTexture(
            size: output.size,
            scaleFactor: 1,
            format: output.pixelFormat,
            debugLabel: label,
            samplerDescription: .init(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped)
        )
    }

    private func beginDraw(
        command: any CommandBuffer,
        color: RenderTexture,
        depth: RenderTexture,
        clearColor: Bool,
        label: String
    ) -> any RenderCommandEncoder {
        command.beginRenderPass(
            .init(
                label: label,
                colorAttachments: [
                    .init(
                        texture: color,
                        operation: .init(loadAction: clearColor ? .clear : .load, storeAction: .store),
                        clearColor: .white
                    )
                ],
                depthStencilAttachment: .init(
                    texture: depth,
                    depthOperation: .init(loadAction: .clear, storeAction: .dontCare),
                    stencilOperation: .init(loadAction: .clear, storeAction: .dontCare)
                )
            )
        )
    }

    private mutating func preparePipelines(format: PixelFormat, device: RenderDevice) {
        guard pipelineFormat != format else {
            return
        }
        let merge = CorePipelineShaders.loadRequiredBuiltin("shadow_merge_3d")
        let clear = CorePipelineShaders.loadRequiredBuiltin("shadow_clear_3d")
        var mergeDescriptor = RenderPipelineDescriptor(
            vertex: merge.asset.requiredShader(for: .vertex),
            fragment: merge.asset.getShader(for: .fragment),
            debugName: "Shadow Depth Merge",
            backfaceCulling: false
        )
        mergeDescriptor.colorAttachments = [.init(format: format)]
        mergeDescriptor.unfilterableTextureBindings = [0: [0, 1]]
        mergeDescriptor.depthStencilDescriptor = nil
        mergePipeline = device.createRenderPipeline(from: mergeDescriptor)
        var clearDescriptor = RenderPipelineDescriptor(
            vertex: clear.asset.requiredShader(for: .vertex),
            fragment: clear.asset.getShader(for: .fragment),
            debugName: "Static Shadow Tile Clear",
            backfaceCulling: false
        )
        clearDescriptor.colorAttachments = [.init(format: format)]
        clearDescriptor.depthStencilDescriptor = .init(isDepthTestEnabled: false, isDepthWriteEnabled: false, depthCompareOperator: .always)
        clearPipeline = device.createRenderPipeline(from: clearDescriptor)
        pipelineFormat = format
    }
}

func encodeCachedShadowTile<P: RenderPipelineConfigurator>(
    _ tile: ShadowMapCache3D.Tile,
    isMoving: Bool,
    pass: any RenderCommandEncoder,
    view: Entity.ID,
    lists: VisibleMesh3DLists,
    batches: inout ShadowBatchEncoder3D,
    pipelines: inout RenderPipelines<P>,
    materials: PBR3DUniforms,
    identity: (any UniformBuffer)?,
    device: RenderDevice
) where P.Configuration == Shadow3DConfiguration {
    let list = tile.firstList + (isMoving ? 1 : 0)
    let buffers = lists.buffers(view: view, pass: list)
    guard let instances = buffers.instances else {
        return
    }
    pass.setVertexBuffer(tile.constants, offset: 0, slot: GlobalBufferIndex.viewUniform)
    batches.encode(
        items: lists.items(view: view, pass: list),
        instances: instances,
        defaults: buffers.defaults,
        pass: pass,
        pipelines: &pipelines,
        materials: materials,
        identityPalette: identity,
        device: device
    )
}
