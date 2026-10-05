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

    @Res<RenderItems<Opaque3DRenderItem>>
    private var renderItems

    @Res<ExtractedMesh3DSources> private var candidates
    @ResMut<VisibleMesh3DLists> private var lists
    @ResMut<Active3DInstanceBuffers> private var activeInstances
    @ResMut<PBR3DUniforms> private var materials
    @Res<Render3DVisibilityStatistics> private var statistics

    @Res<ExtractedLighting3D>
    private var lighting

    @Res<ExtractedEnvironment3D> private var environments
    @ResMut<IBL3DScratch> private var ibl

    @ResMut<Lighting3DGPUScratch>
    private var lightingScratch

    @Res<RenderDeviceHandler>
    private var renderDevice

    @Res<Render3DPerformanceMetrics?> private var metrics

    public init() {}

    public let inputResources: [RenderSlot] = [
        RenderSlot(name: InputNode.view, kind: .entity),
    ]

    public func update(from world: World) {
        _metrics.update(from: world)
        query.update(from: world)
        _renderItems.update(from: world)
        _lighting.update(from: world)
        _candidates.update(from: world)
        _lists.update(from: world)
        _activeInstances.update(from: world)
        _materials.update(from: world)
        _statistics.update(from: world)
        _lightingScratch.update(from: world)
        _environments.update(from: world)
        _ibl.update(from: world)
        _renderDevice.update(from: world)
        var activeViews: [Entity.ID] = []
        query.forEach { _, _, _, _, source in activeViews.append(source.entityId) }
        lightingScratch.cache.retainViews(activeViews)
        lists.retainViews(activeViews)
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity else {
            return []
        }
        // The shadow node updates this resource earlier in the same graph execution. Fetch it here instead of
        // caching it in update(from:) so the sampled texture and its projection matrix always belong to one frame.
        guard let shadow = context.world.getResource(DirectionalShadow3D.self) else {
            return []
        }

        var submitted: CommandBuffer?
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
            let visibleItems = lists.items(view: source.entityId, pass: -1)
            _activeInstances.wrappedValue = lists.buffers(view: source.entityId, pass: -1)
            statistics.record(lists.count(view: source.entityId, pass: -1), view: source.entityId, pass: -1)

            let clearColor = camera.clearFlags.contains(.solid) ? camera.backgroundColor : .surfaceClearColor
            let directionalLight =
                lighting.directionalLight
                    ?? ExtractedDirectionalLight3D(
                        directionToLight: Vector3(0.35, 0.7, 0.45).normalized,
                        radiance: .one,
                        intensity: 3.2
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
                        1 / Float(DirectionalShadow3D.resolution)
                    ),
                    shadowViewProjection1: shadow.viewProjection1,
                    shadowViewProjection2: shadow.viewProjection2,
                    cascadeSplits: shadow.cascadeSplits,
                    shadowAtlas: Vector4(1 / Float(shadow.colorTexture?.size.width ?? 1024), 1 / Float(shadow.colorTexture?.size.height ?? 1024), shadow.blendFraction, 0)
                ),
                view: source.entityId,
                device: renderDevice.renderDevice
            )

            let commandBuffer = renderContext.commandQueue.makeCommandBuffer()
            commandBuffer.label = "Main 3d Render Pass"

            let depthAttachment = target.depthTexture.map {
                DepthStencilAttachmentDescriptor(
                    texture: $0,
                    depthOperation: OperationDescriptor(loadAction: .clear, storeAction: .store),
                    stencilOperation: OperationDescriptor(loadAction: .clear, storeAction: .store)
                )
            }

            let renderPass = commandBuffer.beginRenderPass(
                RenderPassDescriptor(
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
            )

            renderPass.setVertexBuffer(uniform, slot: GlobalBufferIndex.viewUniform)
            renderPass.setVertexBuffer(lightConstants, offset: 0, slot: 1)
            renderPass.setFragmentBuffer(lightConstants, offset: 0, slot: 1)
            let shadowTexture = shadow.colorTexture ?? Texture2D.whiteTexture
            renderPass.setResourceSet(
                RenderResourceSet(
                    bindings: [
                        .init(binding: 10, shaderStages: .fragment, resource: .texture(shadowTexture)),
                        .init(binding: 11, shaderStages: .fragment, resource: .sampler(shadowTexture.sampler)),
                    ]
                ),
                index: 0
            )
            let settings = environments.environments[source.entityId]?.imageBasedLighting
            let environment = settings?.asset.asset
            ibl.uniform.elements = [
                IBL3DUniform(
                    inverseView: uniform.viewMatrix.inverse,
                    parameters: Vector4(environment == nil ? 0 : 1, max(0, settings?.intensity ?? 1), Float(environment?.specularLevels ?? 2), settings?.rotation ?? 0)
                ),
            ]
            ibl.uniform.write(to: renderDevice.renderDevice)
            let diffuse = environment?.irradiance ?? Texture2D.whiteTexture
            let specular = environment?.specular ?? Texture2D.whiteTexture
            let lut = environment?.brdf ?? Texture2D.whiteTexture
            renderPass.setResourceSet(RenderResourceSet(bindings: [
                .init(binding: 18, shaderStages: .fragment, resource: .texture(diffuse)),
                .init(binding: 19, shaderStages: .fragment, resource: .texture(specular)),
                .init(binding: 20, shaderStages: .fragment, resource: .texture(lut)),
                .init(binding: 3, shaderStages: .fragment, resource: .sampler(diffuse.sampler)),
            ]), index: 0)
            renderPass.setFragmentBuffer(ibl.uniform, offset: 0, slot: 22)
            renderPass.setViewport(camera.viewport.rect)

            if !visibleItems.isEmpty {
                if visibleItems.contains(where: { ($0.material as? PBRMaterial)?.alphaMode == .blend }) {
                    let sorted = visibleItems.enumerated().sorted { left, right in
                        let lhs = left.element
                        let rhs = right.element
                        let leftBlend = (lhs.material as? PBRMaterial)?.alphaMode == .blend
                        let rightBlend = (rhs.material as? PBRMaterial)?.alphaMode == .blend
                        if leftBlend != rightBlend {
                            return !leftBlend
                        }
                        if !leftBlend {
                            return left.offset < right.offset
                        }
                        let leftDepth = (uniform.viewMatrix * lhs.worldTransform.w).z
                        let rightDepth = (uniform.viewMatrix * rhs.worldTransform.w).z
                        return leftDepth == rightDepth ? left.offset < right.offset : leftDepth > rightDepth
                    }.map(\.element)
                    var ordered = renderItems
                    ordered.items = sorted
                    try ordered.render(with: renderPass, world: context.world, view: view)
                } else {
                    try RenderItems<Opaque3DRenderItem>(items: visibleItems).render(with: renderPass, world: context.world, view: view)
                }
            }

            renderPass.endRenderPass()
            if let metrics {
                commandBuffer.addCompletedTimingHandler { metrics.record(pass: "geometry", seconds: $0) }
            }
            submitted = commandBuffer
        }

        if let submitted {
            if let metrics { await metrics.commit(submitted) } else { submitted.commit() }
        }
        return []
    }
}
