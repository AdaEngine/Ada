//
//  WebGPURenderDevice.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 28.12.2025.
//

#if WEBGPU_ENABLED && canImport(WebGPU)
    import AdaUtils
    import Foundation
    import Synchronization
    @unsafe @preconcurrency import WebGPU

    @_spi(Internal)
    public final class WebGPURenderDevice: RenderDevice, @unchecked Sendable {
        public let context: WGPUContext

        init(context: WGPUContext) {
            self.context = context
        }

        public func createUniformBuffer(length: Int, binding: Int) -> any UniformBuffer {
            // WebGPU requires uniform buffers to be aligned to 16 bytes for proper struct alignment
            let alignedLength = (length + 15) & ~15
            let _buffer =
                webGPUDeviceLock.withLock { _ in
                    context.device.createBuffer(
                        descriptor: WebGPU.GPUBufferDescriptor(
                            usage: [.indirect, .copyDst, .copySrc, .uniform],
                            size: UInt64(alignedLength)
                        )
                    )
                }
                .unwrap(message: "Failed to create uniform buffer")
            return WGPUUniformBuffer(buffer: _buffer, device: context.device, binding: binding)
        }

        public func createVertexBuffer(label: String?, length: Int, binding: Int) -> any VertexBuffer {
            let _buffer =
                webGPUDeviceLock.withLock { _ in
                    context.device.createBuffer(
                        descriptor: WebGPU.GPUBufferDescriptor(
                            label: label,
                            usage: [.vertex, .copyDst, .copySrc],
                            size: UInt64(length)
                        )
                    )
                }
                .unwrap(message: "Failed to create vertex buffer")
            return WGPUVertexBuffer(buffer: _buffer, device: context.device, binding: binding)
        }

        public func createIndexBuffer(label: String?, format: IndexBufferFormat, bytes: UnsafeRawPointer, length: Int) -> any IndexBuffer {
            let _buffer =
                webGPUDeviceLock.withLock { _ in
                    context.device.createBuffer(
                        descriptor: WebGPU.GPUBufferDescriptor(
                            label: label,
                            usage: [.index, .copyDst],
                            size: UInt64(length)
                        )
                    )
                }
                .unwrap(message: "Failed to create index buffer")
            let buffer = WGPUIndexBuffer(buffer: _buffer, device: context.device, indexFormat: format)
            unsafe buffer.setData(UnsafeMutableRawPointer(mutating: bytes), byteCount: length)
            return buffer
        }

        public func createBuffer(label: String?, bytes: UnsafeRawPointer, length: Int, options: ResourceOptions) -> any Buffer {
            let _buffer =
                webGPUDeviceLock.withLock { _ in
                    context.device.createBuffer(
                        descriptor: WebGPU.GPUBufferDescriptor(
                            label: label,
                            usage: options.toWebGPU,
                            size: UInt64(length)
                        )
                    )
                }
                .unwrap(message: "Failed to create buffer")
            let buffer = WGPUBuffer(buffer: _buffer, device: context.device)
            unsafe buffer.setData(UnsafeMutableRawPointer(mutating: bytes), byteCount: length)
            return buffer
        }

        public func createBuffer(label: String?, length: Int, options: ResourceOptions) -> any Buffer {
            let buffer =
                webGPUDeviceLock.withLock { _ in
                    context.device.createBuffer(
                        descriptor: WebGPU.GPUBufferDescriptor(
                            label: label,
                            usage: options.toWebGPU,
                            size: UInt64(length)
                        )
                    )
                }
                .unwrap(message: "Failed to create buffer")
            return WGPUBuffer(buffer: buffer, device: context.device)
        }

        public func compileShader(from shader: Shader) throws -> any CompiledShader {
            return WGPUShader(shader: shader, device: context.device)
        }

        public func createRenderPipeline(from descriptor: RenderPipelineDescriptor) -> any RenderPipeline {
            WGPURenderPipeline(
                descriptor: descriptor,
                device: context.device
            )
        }

        public func createSampler(from descriptor: SamplerDescriptor) -> any Sampler {
            let wgpuSampler = webGPUDeviceLock.withLock { _ in
                context.device.createSampler(
                    descriptor: WebGPU.GPUSamplerDescriptor(
                        label: nil,
                        magFilter: descriptor.magFilter.toWebGPU,
                        minFilter: descriptor.minFilter.toWebGPU,
                        mipmapFilter: descriptor.mipFilter.toWebGPU,
                        lodMinClamp: Double(descriptor.lodMinClamp),
                        lodMaxClamp: Double(descriptor.lodMaxClamp)
                    )
                )
            }
            return WGPUSampler(descriptor: descriptor, wgpuSampler: wgpuSampler)
        }

        public func createUniformBufferSet() -> any UniformBufferSet {
            return unsafe GenericUniformBufferSet(frames: RenderEngine.configurations.maxFramesInFlight, device: self)
        }

        public func createTexture(from descriptor: TextureDescriptor) -> any GPUTexture {
            return WGPUGPUTexture(descriptor: descriptor, device: context.device)
        }

        public func getImage(from texture: Texture) -> Image? {
            return (texture.gpuTexture as? WGPUGPUTexture)?.getImage(device: context.device)
        }

        public func createCommandQueue() -> any CommandQueue {
            return WGPUCommandQueue(device: context.device)
        }

        @MainActor
        public func createSwapchain(from window: WindowID) -> (any Swapchain)? {
            guard let renderWindow = context.getWGPURenderWindow(for: window) else {
                return nil
            }

            return WGPUSwapchain(renderWindow: renderWindow)
        }
    }

    extension ResourceOptions {
        var toWebGPU: WebGPU.GPUBufferUsage {
            switch self {
            case .storageManaged:
                [WebGPU.GPUBufferUsage.storage, .copySrc, .copyDst, .uniform, .vertex, .index]
            case .storageShared:
                [WebGPU.GPUBufferUsage.storage, .copySrc, .copyDst, .uniform, .vertex, .index]
            case .storagePrivate:
                [WebGPU.GPUBufferUsage.indirect, .uniform, .vertex, .index]
            default:
                [.uniform, .vertex, .index, .copyDst]
            }
        }
    }

#endif
