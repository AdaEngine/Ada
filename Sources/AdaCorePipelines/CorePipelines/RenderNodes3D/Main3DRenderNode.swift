//
//  Main3DRenderNode.swift
//  AdaEngine
//
//  Created by Codex on 07/06/26.
//

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
        GlobalViewUniform
    >
    private var query

    @Res<RenderItems<Opaque3DRenderItem>>
    private var renderItems

    @Res<ExtractedLighting3D>
    private var lighting

    @ResMut<Lighting3DGPUScratch>
    private var lightingScratch

    @Res<RenderDeviceHandler>
    private var renderDevice

    public init() {}

    public let inputResources: [RenderSlot] = [
        RenderSlot(name: InputNode.view, kind: .entity)
    ]

    public func update(from world: World) {
        query.update(from: world)
        _renderItems.update(from: world)
        _lighting.update(from: world)
        _lightingScratch.update(from: world)
        _renderDevice.update(from: world)
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

        try query.forEach { entity, camera, target, uniform in
            if entity != view {
                return
            }

            guard
                target.rendering3DUsesEnvironmentTargets,
                let sceneColor = target.sceneColor3DTexture,
                let normalRoughness = target.normalRoughness3DTexture,
                let viewPositionMetallic = target.viewPositionMetallic3DTexture
            else {
                return
            }

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
            lightingScratch.directionalLight.elements = [
                DirectionalLight3DUniform(
                    directionIntensity: Vector4(viewDirectionToLight, directionalLight.intensity),
                    radianceAmbient: Vector4(directionalLight.radiance, 0.035),
                    shadowViewProjection: shadow.viewProjection,
                    shadowParameters: Vector4(
                        shadowsEnabled ? 1 : 0,
                        max(0, directionalLight.shadowBias),
                        max(0, directionalLight.shadowSlopeBias),
                        1 / Float(DirectionalShadow3D.resolution)
                    )
                )
            ]
            lightingScratch.directionalLight.write(to: renderDevice.renderDevice)

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
                    ],
                    depthStencilAttachment: depthAttachment
                )
            )

            renderPass.setVertexBuffer(uniform, slot: GlobalBufferIndex.viewUniform)
            renderPass.setVertexBuffer(lightingScratch.directionalLight, offset: 0, slot: 1)
            renderPass.setFragmentBuffer(lightingScratch.directionalLight, offset: 0, slot: 1)
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
            renderPass.setViewport(camera.viewport.rect)

            if !renderItems.items.isEmpty {
                try renderItems.render(with: renderPass, world: context.world, view: view)
            }

            renderPass.endRenderPass()
            commandBuffer.commit()
        }

        return []
    }
}
