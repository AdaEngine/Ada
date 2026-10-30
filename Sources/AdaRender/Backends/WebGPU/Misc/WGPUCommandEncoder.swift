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
        private(set) var commandEncoder: WebGPU.GPUCommandEncoder
        private let spatialScaler: WGPUFSRSpatialScaler
        private let instance: WebGPU.GPUInstance?
        private var completedHandlers: [@Sendable () -> Void] = []

        init(device: WebGPU.GPUDevice, spatialScaler: WGPUFSRSpatialScaler, instance: WebGPU.GPUInstance? = nil) {
            self.spatialScaler = spatialScaler
            self.device = device
            self.instance = instance
            self.commandEncoder = webGPUDeviceLock.withLock { _ in
                device.createCommandEncoder(descriptor: nil)
            }
        }

        func commit() {
            let commandBuffer: WebGPU.GPUCommandBuffer = webGPUDeviceLock.withLock { _ in
                commandEncoder.finish(descriptor: nil as WebGPU.GPUCommandBufferDescriptor?)
            }
            let handlers = completedHandlers
            completedHandlers.removeAll()
            #if WASM
            webGPUDeviceLock.withLock { _ in
                device.queue.submit(commands: [commandBuffer])
            }
            handlers.forEach { $0() }
            #else
            let completion = handlers.isEmpty ? nil : WGPUCommandCompletion(instance: instance, command: commandBuffer, handlers: handlers)
            webGPUDeviceLock.withLock { _ in
                device.queue.submit(commands: [commandBuffer])
                if let completion {
                    let info = WebGPU.GPUQueueWorkDoneCallbackInfo(
                        mode: instance == nil ? .allowSpontaneous : .allowProcessEvents,
                        callback: { _, _ in completion.complete() }
                    )
                    // Swan's generated one-shot callback wrapper retains its Swift closure
                    // without releasing it. Transfer that retain back on the callback.
                    info.withWGPUStruct { native in
                        native.callback = { status, message, userdata, _ in
                            guard let userdata else { return }
                            let callback = Unmanaged<AnyObject>.fromOpaque(userdata).takeRetainedValue() as! WebGPU.GPUQueueWorkDoneCallback
                            callback(status, message.toString)
                        }
                        _ = device.queue.onSubmittedWorkDone(callbackInfo: native)
                    }
                }
            }
            completion?.pumpEvents()
            #endif
        }

        func addCompletedHandler(_ handler: @escaping @Sendable () -> Void) {
            completedHandlers.append(handler)
        }

        /// Ends this command segment before an external GPU pass, then resumes
        /// encoding. Completion handlers cover every segment and the external pass.
        func withExternalGPUWork(_ work: () -> Bool) -> Bool {
            webGPUDeviceLock.withLock { _ in
                let prefix = commandEncoder.finish(descriptor: nil as WebGPU.GPUCommandBufferDescriptor?)
                device.queue.submit(commands: [prefix])
                let encoded = work()
                commandEncoder = device.createCommandEncoder(descriptor: nil)
                return encoded
            }
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

        func encodeSpatialUpscale(source: Texture, destination: Texture) -> Bool {
            guard let input = source.gpuTexture as? WGPUGPUTexture,
                let output = destination.gpuTexture as? WGPUGPUTexture else {
                return false
            }
            return spatialScaler.encode(source: input, destination: output, command: self)
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
