//
//  UpscaleNode.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 26.11.2025.
//

import AdaECS
@_spi(Internal) import AdaRender
import Math

/// This node is responsible for presenting the result to the screen.
public struct UpscaleNode: RenderNode {
    public enum InputNode {
        public static let view: RenderSlot.Label = "view"
    }

    public let inputResources: [RenderSlot] = [
        RenderSlot(name: InputNode.view, kind: .entity)
    ]

    public init() {}

    public func execute(
        context: inout Context,
        renderContext: RenderContext
    ) async throws -> [RenderSlotValue] {
        guard
            let viewEntity = context.viewEntity,
            let target = context.world.get(RenderViewTarget.self, from: viewEntity.id),
            let camera = context.world.get(Camera.self, from: viewEntity.id)
        else {
            return []
        }

        if let mainTexture = target.mainTexture,
            let outputTexture = target.outputTexture,
            mainTexture !== outputTexture {
            let commandBuffer = renderContext.commandQueue.makeCommandBuffer()
            commandBuffer.label = "Upscale Pass"

            if commandBuffer.encodeSpatialUpscale(source: mainTexture, destination: outputTexture) {
                commandBuffer.addCompletedHandler { [outputTexture] in
                    outputTexture.notifyRenderCompleted()
                }
                commandBuffer.commit()
                return []
            }

            guard let upscalePipeline = context.world.getResource(UpscalePipeline.self) else {
                return []
            }

            let renderPass = commandBuffer.beginRenderPass(
                RenderPassDescriptor(
                    label: "Upscale Pass",
                    colorAttachments: [
                        .init(
                            texture: outputTexture,
                            operation: OperationDescriptor(
                                loadAction: .clear,
                                storeAction: .store
                            ),
                            clearColor: camera.backgroundColor
                        )
                    ],
                    depthStencilAttachment: nil
                )
            )

            let resourceSet = RenderResourceSet(
                bindings: [
                    RenderResourceSet.Binding(
                        binding: 0,
                        shaderStages: .fragment,
                        resource: .texture(mainTexture)
                    ),
                    RenderResourceSet.Binding(
                        binding: 1,
                        shaderStages: .fragment,
                        resource: .sampler(upscalePipeline.sampler)
                    ),
                ]
            )
            renderPass.setResourceSet(resourceSet, index: 0)
            renderPass.setRenderPipelineState(upscalePipeline.renderPipeline)
            renderPass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            renderPass.endRenderPass()
            commandBuffer.addCompletedHandler { [outputTexture] in
                outputTexture.notifyRenderCompleted()
            }
            commandBuffer.commit()
        }

        return []
    }
}
