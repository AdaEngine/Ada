//
//  MetalCommandEncoder.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 23.11.2025.
//

#if canImport(Metal)
    import AdaUtils
    import Math
    import Metal

    final class MetalCommandEncoder: CommandBuffer {
        var label: String?
        let commandBuffer: MTLCommandBuffer
        private let device: MTLDevice
        #if canImport(MetalFX) && (os(macOS) || os(iOS))
            private let spatialScalerCache: MetalSpatialScalerCache
        #endif

        #if canImport(MetalFX) && (os(macOS) || os(iOS))
            init(
                commandBuffer: MTLCommandBuffer,
                device: MTLDevice,
                spatialScalerCache: MetalSpatialScalerCache
            ) {
                self.commandBuffer = commandBuffer
                self.device = device
                self.spatialScalerCache = spatialScalerCache
            }
        #else
            init(commandBuffer: MTLCommandBuffer, device: MTLDevice) {
                self.commandBuffer = commandBuffer
                self.device = device
            }
        #endif

        func commit() {
            self.commandBuffer.commit()
        }

        func addCompletedHandler(_ handler: @escaping @Sendable () -> Void) {
            self.commandBuffer.addCompletedHandler { _ in
                handler()
            }
        }

        func beginRenderPass(_ desc: RenderPassDescriptor) -> RenderCommandEncoder {
            let renderPassDescriptor = MTLRenderPassDescriptor()
            let attachments = desc.colorAttachments

            for (index, attachment) in attachments.enumerated() {
                let colorAttachment = renderPassDescriptor.colorAttachments[index]
                colorAttachment?.texture = (attachment.texture.gpuTexture as! MetalGPUTexture).texture
                colorAttachment?.loadAction = attachment.operation?.loadAction.toMetal ?? .dontCare
                colorAttachment?.storeAction = attachment.operation?.storeAction.toMetal ?? .dontCare
                colorAttachment?.clearColor = attachment.clearColor?.toMetalClearColor ?? Color.black.toMetalClearColor
            }

            if let depthStencilAttachment = desc.depthStencilAttachment {
                renderPassDescriptor.depthAttachment.texture = (depthStencilAttachment.texture.gpuTexture as! MetalGPUTexture).texture
                renderPassDescriptor.depthAttachment.loadAction = depthStencilAttachment.depthOperation?.loadAction.toMetal ?? .dontCare
                renderPassDescriptor.depthAttachment.storeAction = depthStencilAttachment.depthOperation?.storeAction.toMetal ?? .dontCare
                // renderPassDescriptor.depthAttachment.clearDepth = Double(depthStencilAttachment.depthOperation?.clearDepth ?? 0)
                // renderPassDescriptor.depthAttachment.clearStencil = UInt32(depthStencilAttachment.stencilOperation?.clearStencil ?? 0)
                renderPassDescriptor.stencilAttachment.texture = (depthStencilAttachment.texture.gpuTexture as! MetalGPUTexture).texture
                renderPassDescriptor.stencilAttachment.loadAction = depthStencilAttachment.stencilOperation?.loadAction.toMetal ?? .dontCare
                renderPassDescriptor.stencilAttachment.storeAction = depthStencilAttachment.stencilOperation?.storeAction.toMetal ?? .dontCare
                // renderPassDescriptor.stencilAttachment.clearStencil = UInt32(depthStencilAttachment.stencilOperation?.clearStencil ?? 0)
            }

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                fatalError("Failed to create MTLRenderCommandEncoder")
            }
            encoder.label = desc.label
            return MetalRenderCommandEncoder(
                renderEncoder: encoder,
                device: device
            )
        }

        func beginBlitPass(_ desc: BlitPassDescriptor) -> BlitCommandEncoder {
            guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
                fatalError("Failed to create MTLBlitCommandEncoder")
            }
            encoder.label = desc.label
            return MetalBlitCommandEncoder(blitEncoder: encoder)
        }

        func encodeSpatialUpscale(source: Texture, destination: Texture) -> Bool {
            #if canImport(MetalFX) && (os(macOS) || os(iOS))
                guard
                    let sourceTexture = source.gpuTexture as? MetalGPUTexture,
                    let destinationTexture = destination.gpuTexture as? MetalGPUTexture
                else {
                    return false
                }

                return spatialScalerCache.encode(
                    source: sourceTexture.texture,
                    destination: destinationTexture.texture,
                    commandBuffer: commandBuffer
                )
            #else
                return false
            #endif
        }
    }
#endif
