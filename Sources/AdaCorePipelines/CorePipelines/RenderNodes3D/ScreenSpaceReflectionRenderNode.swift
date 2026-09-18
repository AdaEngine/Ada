//
//  ScreenSpaceReflectionRenderNode.swift
//  AdaEngine
//

import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

/// Composites screen-space reflections and the camera skybox into the main target.
public struct ScreenSpaceReflectionRenderNode: RenderNode {
    public static let name: RenderNodeLabel = .screenSpaceReflection

    @Query<Entity, Camera, RenderViewTarget, GlobalViewUniform, ExtractedCameraSource>
    private var query

    @Res<ExtractedEnvironment3D>
    private var environments

    @Res<ScreenSpaceReflectionPipeline>
    private var pipeline

    @ResMut<ScreenSpaceReflectionScratch>
    private var scratch

    @Res<RenderDeviceHandler>
    private var renderDevice

    private let notifiesCompletion: Bool

    public init(notifiesCompletion: Bool = true) {
        self.notifiesCompletion = notifiesCompletion
    }

    public func update(from world: World) {
        query.update(from: world)
        _environments.update(from: world)
        _pipeline.update(from: world)
        _scratch.update(from: world)
        _renderDevice.update(from: world)
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity else {
            return []
        }

        query.forEach { entity, camera, target, viewUniform, source in
            guard
                entity == view,
                target.rendering3DUsesEnvironmentTargets,
                let sceneColor = target.sceneColor3DTexture,
                let normalRoughness = target.normalRoughness3DTexture,
                let viewPositionMetallic = target.viewPositionMetallic3DTexture,
                let mainTexture = target.mainTexture
            else {
                return
            }

            let environment = environments.environments[source.entityId] ?? Environment3D()
            let skybox = environment.skybox
            let reflection = environment.screenSpaceReflection
            let skyIntensity = max(0, skybox.intensity)
            let uniform = Environment3DUniform(
                projection: viewUniform.projectionMatrix,
                inverseProjection: viewUniform.projectionMatrix.inverse,
                inverseView: viewUniform.viewMatrix.inverse,
                zenithColor: skybox.zenithColor.asVector,
                horizonColor: skybox.horizonColor.asVector,
                groundColor: skybox.groundColor.asVector,
                clearColor: camera.backgroundColor.asVector,
                reflection: Vector4(
                    reflection.isEnabled ? 1 : 0,
                    max(0, reflection.maxDistance),
                    max(0.001, reflection.stride),
                    max(0.001, reflection.thickness)
                ),
                reflectionQuality: Vector4(
                    Float(min(max(reflection.maxSteps, 1), 64)),
                    max(0, reflection.intensity),
                    min(max(reflection.edgeFade, 0.001), 0.5),
                    0
                ),
                environmentFlags: Vector4(
                    skybox.isEnabled ? 1 : 0,
                    skybox.texture == nil ? 0 : 1,
                    skyIntensity,
                    skybox.starfield.isEnabled ? 1 : 0
                ),
                starfield: Vector4(
                    min(max(skybox.starfield.density, 0), 1),
                    max(skybox.starfield.intensity, 0),
                    max(skybox.starfield.size, 0.1),
                    skybox.starfield.seed
                )
            )
            scratch.uniform.elements = [uniform]
            scratch.uniform.write(to: renderDevice.renderDevice)

            let environmentTexture = skybox.texture?.asset ?? Texture2D.whiteTexture
            let commandBuffer = renderContext.commandQueue.makeCommandBuffer()
            commandBuffer.label = "Screen Space Reflection Composite"
            let pass = commandBuffer.beginRenderPass(
                RenderPassDescriptor(
                    label: "Screen Space Reflection Composite",
                    colorAttachments: [
                        .init(
                            texture: mainTexture,
                            operation: OperationDescriptor(loadAction: .clear, storeAction: .store),
                            clearColor: camera.backgroundColor
                        )
                    ],
                    depthStencilAttachment: nil
                )
            )
            pass.setViewport(camera.viewport.rect)
            pass.setResourceSet(
                RenderResourceSet(
                    bindings: [
                        .init(binding: 0, shaderStages: .fragment, resource: .texture(sceneColor)),
                        .init(binding: 1, shaderStages: .fragment, resource: .texture(normalRoughness)),
                        .init(binding: 2, shaderStages: .fragment, resource: .texture(viewPositionMetallic)),
                        .init(binding: 3, shaderStages: .fragment, resource: .sampler(pipeline.sampler)),
                        .init(binding: 5, shaderStages: .fragment, resource: .texture(environmentTexture)),
                    ]
                ),
                index: 0
            )
            pass.setFragmentBuffer(scratch.uniform, offset: 0, slot: 4)
            pass.setRenderPipelineState(pipeline.renderPipeline)
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            pass.endRenderPass()
            if notifiesCompletion, let outputTexture = target.outputTexture,
                mainTexture === outputTexture {
                commandBuffer.addCompletedHandler { [outputTexture] in
                    outputTexture.notifyRenderCompleted()
                }
            }
            commandBuffer.commit()
        }

        return []
    }
}
