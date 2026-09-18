//
//  MetalRenderPipeline.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/18/23.
//

#if METAL
    @unsafe @preconcurrency import Metal

    final class MetalRenderPipeline: RenderPipeline {
        let descriptor: RenderPipelineDescriptor
        let renderPipeline: MTLRenderPipelineState
        let depthStencilState: MTLDepthStencilState?

        init(
            descriptor: RenderPipelineDescriptor,
            device: MTLDevice
        ) throws {
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.label = descriptor.debugName

            let vertexDescriptor = MTLVertexDescriptor()

            for (index, attribute) in descriptor.vertexDescriptor.attributes.enumerated() {
                guard attribute.format != .invalid else {
                    continue
                }

                vertexDescriptor.attributes[index].offset = attribute.offset
                vertexDescriptor.attributes[index].bufferIndex = attribute.bufferIndex
                vertexDescriptor.attributes[index].format = attribute.format.metalFormat
            }

            for (index, layout) in descriptor.vertexDescriptor.layouts.enumerated() {
                vertexDescriptor.layouts[index].stride = layout.stride
                vertexDescriptor.layouts[index].stepFunction = layout.stepFunction == .perInstance ? .perInstance : .perVertex
            }
            if let shader = descriptor.vertex.compiledShader as? MetalShader {
                pipelineDescriptor.vertexFunction = shader.function
            }

            if let shader = descriptor.fragment?.compiledShader as? MetalShader {
                pipelineDescriptor.fragmentFunction = shader.function
            }

            pipelineDescriptor.vertexDescriptor = vertexDescriptor

            for (index, attachment) in descriptor.colorAttachments.enumerated() {
                guard let colorAttachment = pipelineDescriptor.colorAttachments[index] else {
                    preconditionFailure("Metal did not create color attachment \(index).")
                }

                colorAttachment.pixelFormat = attachment.format.toMetal
                colorAttachment.isBlendingEnabled = attachment.isBlendingEnabled
                colorAttachment.rgbBlendOperation = attachment.rgbBlendOperation.toMetal
                colorAttachment.alphaBlendOperation = attachment.alphaBlendOperation.toMetal
                colorAttachment.sourceRGBBlendFactor = attachment.sourceRGBBlendFactor.toMetal
                colorAttachment.sourceAlphaBlendFactor = attachment.sourceAlphaBlendFactor.toMetal
                colorAttachment.destinationRGBBlendFactor = attachment.destinationRGBBlendFactor.toMetal
                colorAttachment.destinationAlphaBlendFactor = attachment.destinationAlphaBlendFactor.toMetal
            }

            var depthStencilState: MTLDepthStencilState?

            if let depthStencilDesc = descriptor.depthStencilDescriptor {
                pipelineDescriptor.depthAttachmentPixelFormat = descriptor.depthPixelFormat.toMetal
                pipelineDescriptor.stencilAttachmentPixelFormat = descriptor.depthPixelFormat.toMetal

                let depthStencilDescriptor = MTLDepthStencilDescriptor()
                depthStencilDescriptor.depthCompareFunction = depthStencilDesc.depthCompareOperator.toMetal
                depthStencilDescriptor.isDepthWriteEnabled = depthStencilDesc.isDepthWriteEnabled

                if depthStencilDesc.isEnableStencil {
                    guard let stencilDesc = depthStencilDesc.stencilOperationDescriptor else {
                        fatalError("StencilOperationDescriptor instance not passed to DepthStencilDescriptor object.")
                    }

                    let stencilDescriptor = MTLStencilDescriptor()
                    stencilDescriptor.depthFailureOperation = stencilDesc.depthFail.toMetal
                    stencilDescriptor.depthStencilPassOperation = stencilDesc.pass.toMetal
                    stencilDescriptor.stencilFailureOperation = stencilDesc.fail.toMetal
                    stencilDescriptor.stencilCompareFunction = stencilDesc.compare.toMetal

                    depthStencilDescriptor.backFaceStencil = stencilDescriptor
                    depthStencilDescriptor.frontFaceStencil = stencilDescriptor
                }

                depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)
            }

            let state = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            self.descriptor = descriptor
            self.renderPipeline = state
            self.depthStencilState = depthStencilState
        }
    }
#endif
