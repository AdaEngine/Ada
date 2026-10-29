//
//  Main3DRenderNode.swift
//  AdaEngine
//
//  Created by Codex on 07/06/26.
//

import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

/// This render node is responsible for rendering opaque 3D meshes.
public struct Main3DRenderNode: RenderNode {
    /// Input slots of render node.
    public enum InputNode {
        public static let view: RenderSlot.Label = "view"
    }

    @Query<
        Entity,
        Camera,
        RenderViewTarget,
        GlobalViewUniform,
        ExtractedCameraSource
    >
    private var query

    @ResMut<VisibleMesh3DLists> private var lists
    @ResMut<GPUVisibility3DState> private var gpuVisibility
    @ResMut<Active3DInstanceBuffers> private var activeInstances
    @ResMut<PBR3DUniforms> private var materials
    @Res<Render3DVisibilityStatistics> private var statistics

    @Res<ExtractedLighting3D>
    private var lighting

    @Res<ExtractedEnvironment3D> private var environments
    @ResMut<IBL3DScratch> private var ibl

    @ResMut<LocalLighting3DGPUScratch> private var localUniforms

    @ResMut<LightTiles3DScratch> private var lightTiles

    @ResMut<Lighting3DGPUScratch>
    private var lightingScratch

    @ResMut<View3DGPUScratch> private var viewUniforms

    @Res<RenderDeviceHandler>
    private var renderDevice

    @Res<Render3DPerformanceMetrics?> private var metrics

    public init() {}

    public let inputResources: [RenderSlot] = [
        RenderSlot(name: InputNode.view, kind: .entity)
    ]

    public func update(from world: World) {
        _metrics.update(from: world)
        query.update(from: world)
        _lighting.update(from: world)
        _lists.update(from: world)
        _gpuVisibility.update(from: world)
        _activeInstances.update(from: world)
        _materials.update(from: world)
        _statistics.update(from: world)
        _lightingScratch.update(from: world)
        _viewUniforms.update(from: world)
        _localUniforms.update(from: world)
        _lightTiles.update(from: world)
        _environments.update(from: world)
        _ibl.update(from: world)
        _renderDevice.update(from: world)
        var activeViews: [Entity.ID] = []
        query.forEach { _, _, _, _, source in activeViews.append(source.entityId) }
        lightingScratch.cache.retainViews(activeViews)
        viewUniforms.cache.retainViews(activeViews)
        ibl.cache.retainViews(activeViews)
        lightTiles.retainViews(activeViews)
        lists.retainViews(activeViews)
        gpuVisibility.retainViews(activeViews)
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        // Keep geometry only while encoding this view. A retained Res snapshot
        // forces extraction to copy the whole array when even one mesh moves.
        guard let view = context.viewEntity,
            let candidates = context.world.getResource(ExtractedMesh3DSources.self) else {
            return []
        }
        // The shadow node updates this resource earlier in the same graph execution. Fetch it here instead of
        // caching it in update(from:) so the sampled texture and its projection matrix always belong to one frame.
        guard let shadow = context.world.getResource(DirectionalShadow3D.self) else {
            return []
        }

        var submitted: CommandBuffer?
        var visibilityCommand: CommandBuffer?
        try query.forEach { entity, camera, target, uniform, source in
            if entity != view {
                return
            }

            guard
                target.rendering3DUsesEnvironmentTargets,
                let sceneColor = target.sceneColor3DTexture,
                let normalRoughness = target.normalRoughness3DTexture,
                let viewPositionMetallic = target.viewPositionMetallic3DTexture,
                let indirect = target.indirectLighting3DTexture
            else {
                return
            }

            lists.prepare(
                sources: candidates.meshes,
                view: source.entityId,
                pass: -1,
                viewMatrix: uniform.viewMatrix,
                projection: uniform.projectionMatrix,
                cullingProjection: uniform.viewProjectionMatrix,
                settings: environments.environments[source.entityId]?.meshVisibility ?? MeshVisibilitySettings3D(),
                device: renderDevice.renderDevice,
                materials: &_materials.wrappedValue
            )
            var visibleItems = lists.items(view: source.entityId, pass: -1)
            _activeInstances.wrappedValue = lists.buffers(view: source.entityId, pass: -1)
            statistics.record(lists.count(view: source.entityId, pass: -1), view: source.entityId, pass: -1)

            let drawUniform = temporalViewUniform(uniform, target: target)
            if environments.environments[source.entityId]?.meshVisibility.gpuOcclusion == true {
                visibilityCommand = gpuVisibility.encode(
                    view: source.entityId,
                    size: sceneColor.size,
                    projection: drawUniform.viewProjectionMatrix,
                    items: &visibleItems,
                    candidates: lists.gpuCandidates(view: source.entityId, pass: -1),
                    buffers: &_activeInstances.wrappedValue,
                    device: renderDevice.renderDevice,
                    queue: renderContext.commandQueue,
                    materials: _materials.wrappedValue,
                    identityPalette: context.world.getResource(Skinning3DUniforms.self)?.identityBuffer,
                    metrics: metrics
                )
            } else {
                gpuVisibility.clearOutput(for: source.entityId)
            }
            let clearColor = camera.clearFlags.contains(.solid) ? camera.backgroundColor : .surfaceClearColor
            let directionalLight =
                lighting.directionalLight
                ?? ExtractedDirectionalLight3D(
                    directionToLight: Vector3(0.35, 0.7, 0.45).normalized,
                    radiance: .one,
                    intensity: lighting.hasAuthoredLights ? 0 : 3.2
                )
            let viewDirectionToLight = (uniform.viewMatrix * Vector4(directionalLight.directionToLight, 0)).xyz.normalized
            let shadowsEnabled = shadow.isEnabled && directionalLight.castsShadows && shadow.colorTexture != nil
            let lightConstants = lightingScratch.cache.write(
                DirectionalLight3DUniform(
                    directionIntensity: Vector4(viewDirectionToLight, directionalLight.intensity),
                    radianceAmbient: Vector4(directionalLight.radiance, 0.035),
                    shadowViewProjection: shadow.viewProjection,
                    shadowParameters: Vector4(
                        shadowsEnabled ? 1 : 0,
                        max(0, directionalLight.shadowBias),
                        max(0, directionalLight.shadowSlopeBias),
                        1 / Float(shadow.colorTexture?.size.height ?? DirectionalShadow3D.resolution)
                    ),
                    shadowViewProjection1: shadow.viewProjection1,
                    shadowViewProjection2: shadow.viewProjection2,
                    cascadeSplits: shadow.cascadeSplits,
                    shadowAtlas: Vector4(
                        1 / Float(shadow.colorTexture?.size.width ?? 1024),
                        1 / Float(shadow.colorTexture?.size.height ?? 1024),
                        shadow.blendFraction,
                        environments.environments[source.entityId]?.debugView.mainPassMode ?? 0
                    )
                ),
                view: source.entityId,
                device: renderDevice.renderDevice
            )

            let localShadows = context.world.getResource(LocalShadow3DViews.self)?.entries[source.entityId]
            let localConstants = localUniforms.write(view: source.entityId, count: 135, device: renderDevice.renderDevice) {
                packLocalLighting(_lighting.wrappedValue, view: uniform.viewMatrix, shadows: localShadows, into: &$0)
            }
            let localMatrices = localUniforms.write(view: source.entityId, pass: 1, count: 97, device: renderDevice.renderDevice) {
                packLocalShadowMatrices(localShadows, into: &$0)
            }
            let localTexture = localShadows?.color ?? Texture2D.whiteTexture

            // Tiles let the main pass skip local lights that cannot reach a pixel. Foveated rendering maps pixels
            // through a rate map the CPU bounds do not model, so it keeps the flat loop.
            let localLights = localShadows?.lights ?? []
            let tileLayout = LightTiles3DMath.layout(width: sceneColor.size.width, height: sceneColor.size.height)
            let tilesActive = (environments.environments[source.entityId]?.tiledLocalLights ?? true) && camera.rasterizationRateMap == nil
            let tileMasks = tilesActive
                ? LightTiles3DMath.masks(
                    spheres: localLights.map { ((uniform.viewMatrix * Vector4($0.position, 1)).xyz, $0.range) },
                    projection: drawUniform.projectionMatrix,
                    viewport: camera.viewport.rect,
                    layout: tileLayout
                )
                : []
            let tileConstants = localUniforms.write(view: source.entityId, pass: 2, count: 6, device: renderDevice.renderDevice) {
                $0[0] = drawUniform.projectionMatrix.x
                $0[1] = drawUniform.projectionMatrix.y
                $0[2] = drawUniform.projectionMatrix.z
                $0[3] = drawUniform.projectionMatrix.w
                $0[4] = [camera.viewport.rect.origin.x, camera.viewport.rect.origin.y, camera.viewport.rect.size.width, camera.viewport.rect.size.height]
                $0[5] = [Float(tileLayout.tileSize), Float(tileLayout.columns), Float(tileLayout.rows), tilesActive ? 1 : 0]
            }
            let tileMaskBuffer = lightTiles.write(view: source.entityId, masks: tileMasks, device: renderDevice.renderDevice)

            let commandBuffer = renderContext.commandQueue.makeCommandBuffer()
            commandBuffer.label = "Main 3d Render Pass"

            let depthAttachment = target.depthTexture.map {
                DepthStencilAttachmentDescriptor(
                    texture: $0,
                    depthOperation: OperationDescriptor(loadAction: .clear, storeAction: .store),
                    stencilOperation: target.temporalUpscalingActive ? nil : OperationDescriptor(loadAction: .clear, storeAction: .store)
                )
            }

            let descriptor = RenderPassDescriptor(
                label: "Main 3d Render Pass",
                colorAttachments: [
                    .init(
                        texture: sceneColor,
                        operation: OperationDescriptor(loadAction: .clear, storeAction: .store),
                        clearColor: clearColor
                    ),
                    .init(
                        texture: normalRoughness,
                        operation: OperationDescriptor(loadAction: .clear, storeAction: .store),
                        clearColor: .black
                    ),
                    .init(
                        texture: viewPositionMetallic,
                        operation: OperationDescriptor(loadAction: .clear, storeAction: .store),
                        clearColor: .black
                    ),
                    .init(texture: indirect, operation: OperationDescriptor(loadAction: .clear, storeAction: .store), clearColor: .black),
                ],
                depthStencilAttachment: depthAttachment
            )
            let foveatedPass = try camera.rasterizationRateMap.map {
                try commandBuffer.beginFoveatedRenderPass(descriptor, rateMap: $0)
            }
            let renderPass = foveatedPass?.encoder ?? commandBuffer.beginRenderPass(descriptor)

            // Stable in-flight buffer identities keep material bind groups reusable
            // across frames; inline bytes allocate a new WebGPU buffer every pass.
            let viewConstants = viewUniforms.cache.write(drawUniform, view: source.entityId, device: renderDevice.renderDevice)
            renderPass.setVertexBuffer(viewConstants, offset: 0, slot: GlobalBufferIndex.viewUniform)
            renderPass.setVertexBuffer(lightConstants, offset: 0, slot: 1)
            renderPass.setFragmentBuffer(lightConstants, offset: 0, slot: 1)
            renderPass.setFragmentBuffer(localConstants, offset: 0, slot: 25)
            renderPass.setFragmentBuffer(localMatrices, offset: 0, slot: 28)
            renderPass.setFragmentBuffer(tileConstants, offset: 0, slot: 27)
            renderPass.setFragmentBuffer(tileMaskBuffer, offset: 0, slot: 29)
            renderPass.setResourceSet(
                RenderResourceSet(bindings: [
                    .init(binding: 26, shaderStages: .fragment, resource: .texture(localTexture))
                ]),
                index: 0
            )
            let shadowTexture = shadow.colorTexture ?? Texture2D.whiteTexture
            renderPass.setResourceSet(
                RenderResourceSet(
                    bindings: [
                        .init(binding: 10, shaderStages: .fragment, resource: .texture(shadowTexture)),
                        .init(binding: 11, shaderStages: .fragment, resource: .sampler(localShadows?.color?.sampler ?? shadowTexture.sampler)),
                    ]
                ),
                index: 0
            )
            let settings = environments.environments[source.entityId]?.imageBasedLighting
            let environment = settings?.asset.asset
            let iblConstants = ibl.cache.write(
                IBL3DUniform(
                    inverseView: uniform.viewMatrix.inverse,
                    parameters: Vector4(environment == nil ? 0 : 1, max(0, settings?.intensity ?? 1), Float(environment?.specularLevels ?? 2), settings?.rotation ?? 0)
                ),
                view: source.entityId,
                device: renderDevice.renderDevice
            )
            let diffuse = environment?.irradiance ?? Texture2D.whiteTexture
            let specular = environment?.specular ?? Texture2D.whiteTexture
            let lut = environment?.brdf ?? Texture2D.whiteTexture
            renderPass.setResourceSet(
                RenderResourceSet(bindings: [
                    .init(binding: 18, shaderStages: .fragment, resource: .texture(diffuse)),
                    .init(binding: 19, shaderStages: .fragment, resource: .texture(specular)),
                    .init(binding: 20, shaderStages: .fragment, resource: .texture(lut)),
                    .init(binding: 3, shaderStages: .fragment, resource: .sampler(diffuse.sampler)),
                ]),
                index: 0
            )
            renderPass.setFragmentBuffer(iblConstants, offset: 0, slot: 22)
            renderPass.setViewport(camera.viewport.rect)
            if environments.environments[source.entityId]?.debugView == .wireframe {
                renderPass.setTriangleFillMode(.lines)
            }

            if !visibleItems.isEmpty {
                // Resolve blend state and view depth once per item instead of inside the comparator.
                let blendFlags = visibleItems.map { ($0.material as? PBRMaterial)?.effectiveAlphaMode == .blend }
                if blendFlags.contains(true) {
                    let viewMatrix = uniform.viewMatrix
                    let keys: [(isBlend: Bool, depth: Float)] = visibleItems.indices.map { index in
                        blendFlags[index] ? (true, (viewMatrix * visibleItems[index].worldTransform.w).z) : (false, 0)
                    }
                    let sorted = visibleItems.indices.sorted { left, right in
                        let leftKey = keys[left]
                        let rightKey = keys[right]
                        if leftKey.isBlend != rightKey.isBlend {
                            return !leftKey.isBlend
                        }
                        if !leftKey.isBlend {
                            return left < right
                        }
                        return leftKey.depth == rightKey.depth ? left < right : leftKey.depth > rightKey.depth
                    }.map { visibleItems[$0] }
                    try RenderItems<Opaque3DRenderItem>(items: sorted).render(with: renderPass, world: context.world, view: view)
                } else {
                    try RenderItems<Opaque3DRenderItem>(items: visibleItems).render(with: renderPass, world: context.world, view: view)
                }
            }

            renderPass.endRenderPass()
            try foveatedPass?.resolve()
            if let metrics {
                commandBuffer.addCompletedTimingHandler { metrics.record(pass: "geometry", seconds: $0) }
            }
            submitted = commandBuffer
        }

        if let visibilityCommand {
            if let metrics { await metrics.commit(visibilityCommand) } else { visibilityCommand.commit() }
        }
        if let submitted {
            if let metrics { await metrics.commit(submitted) } else { submitted.commit() }
        }
        return []
    }
}
