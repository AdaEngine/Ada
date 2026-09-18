//
//  MetalCommandEncoder.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 23.11.2025.
//

#if WEBGPU_ENABLED && canImport(WebGPU)
    import AdaUtils
    import Math
    import Synchronization
    @unsafe @preconcurrency import WebGPU

    final class WGPUCommandEncoder: CommandBuffer {
        var label: String? {
            didSet {
                commandEncoder.setLabel(label: label ?? "")
            }
        }
        let device: WebGPU.GPUDevice
        let commandEncoder: WebGPU.GPUCommandEncoder
        private var completedHandlers: [@Sendable () -> Void] = []

        init(device: WebGPU.GPUDevice) {
            self.device = device
            self.commandEncoder = webGPUDeviceLock.withLock { _ in
                device.createCommandEncoder(descriptor: nil)
            }
        }

        func commit() {
            let commandBuffer: WebGPU.GPUCommandBuffer = commandEncoder.finish(descriptor: nil as WebGPU.GPUCommandBufferDescriptor?)
            webGPUDeviceLock.withLock { _ in
                device.queue.submit(commands: [commandBuffer])
            }
            completedHandlers.forEach { $0() }
            completedHandlers.removeAll()
        }

        func addCompletedHandler(_ handler: @escaping @Sendable () -> Void) {
            completedHandlers.append(handler)
        }

        func beginRenderPass(_ desc: RenderPassDescriptor) -> RenderCommandEncoder {
            var wgpuAttachment: WebGPU.GPURenderPassDepthStencilAttachment?
            if let depthStencilAttachment = desc.depthStencilAttachment {
                let view = (depthStencilAttachment.texture.gpuTexture as! WGPUGPUTexture).textureView
                #if WASM
                    wgpuAttachment = WebGPU.GPURenderPassDepthStencilAttachment(
                        view: view,
                        depthLoadOp: depthStencilAttachment.depthOperation?.loadAction.toWebGPU,
                        depthStoreOp: depthStencilAttachment.depthOperation?.storeAction.toWebGPU,
                        depthClearValue: 1,
                        depthReadOnly: false,
                        stencilLoadOp: depthStencilAttachment.stencilOperation?.loadAction.toWebGPU,
                        stencilStoreOp: depthStencilAttachment.stencilOperation?.storeAction.toWebGPU,
                        stencilClearValue: 1,
                        stencilReadOnly: false
                    )
                #else
                    wgpuAttachment = WebGPU.GPURenderPassDepthStencilAttachment(
                        view: view,
                        depthLoadOp: depthStencilAttachment.depthOperation?.loadAction.toWebGPU ?? .undefined,
                        depthStoreOp: depthStencilAttachment.depthOperation?.storeAction.toWebGPU ?? .undefined,
                        depthClearValue: 1,
                        depthReadOnly: false,
                        stencilLoadOp: depthStencilAttachment.stencilOperation?.loadAction.toWebGPU ?? .undefined,
                        stencilStoreOp: depthStencilAttachment.stencilOperation?.storeAction.toWebGPU ?? .undefined,
                        stencilClearValue: 1,
                        stencilReadOnly: false,
                        nextInChain: nil
                    )
                #endif
            }

            let colorAttachments = desc.colorAttachments.map { attachment in
                #if WASM
                    WebGPU.GPURenderPassColorAttachment(
                        view: (attachment.texture.gpuTexture as! WGPUGPUTexture).textureView,
                        loadOp: attachment.operation?.loadAction.toWebGPU ?? .clear,
                        storeOp: attachment.operation?.storeAction.toWebGPU ?? .store,
                        clearValue: attachment.clearColor?.toWebGPU ?? AdaUtils.Color.black.toWebGPU
                    )
                #else
                    WebGPU.GPURenderPassColorAttachment(
                        view: (attachment.texture.gpuTexture as! WGPUGPUTexture).textureView,
                        resolveTarget: (attachment.resolveTexture?.gpuTexture as? WGPUGPUTexture)?.textureView,
                        loadOp: attachment.operation?.loadAction.toWebGPU ?? .clear,
                        storeOp: attachment.operation?.storeAction.toWebGPU ?? .store,
                        clearValue: attachment.clearColor?.toWebGPU ?? AdaUtils.Color.black.toWebGPU
                    )
                #endif
            }

            let renderPassDescriptor = WebGPU.GPURenderPassDescriptor(
                label: desc.label,
                colorAttachments: colorAttachments,
                depthStencilAttachment: wgpuAttachment
            )

            let renderPassEncoder = commandEncoder.beginRenderPass(
                descriptor: renderPassDescriptor
            )
            return WGPURenderCommandEncoder(renderEncoder: renderPassEncoder, device: device)
        }

        func beginBlitPass(_: BlitPassDescriptor) -> BlitCommandEncoder {
            return WGPUBlitCommandEncoder(
                blitEncoder: commandEncoder,
                device: device
            )
        }
    }

    extension AttachmentLoadAction {
        var toWebGPU: WebGPU.GPULoadOp {
            switch self {
            case .load: return .load
            case .clear: return .clear
            case .dontCare: return .clear
            }
        }
    }

    extension AttachmentStoreAction {
        var toWebGPU: WebGPU.GPUStoreOp {
            switch self {
            case .store: return .store
            case .dontCare: return .discard
            }
        }
    }

    extension AdaUtils.Color {
        var toWebGPU: WebGPU.GPUColor {
            return WebGPU.GPUColor(r: Double(red), g: Double(green), b: Double(blue), a: Double(alpha))
        }
    }

#endif
