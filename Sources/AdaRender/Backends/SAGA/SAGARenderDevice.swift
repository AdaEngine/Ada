//
//  SAGARenderDevice.swift
//  AdaEngine
//

#if SAGA_RENDER && canImport(SAGACompiler)
    import AdaUtils
    import Foundation
    import Math
    import SAGA
    import SAGACore
    import SAGATypes

    @_spi(Internal)
    public final class SAGARenderDevice: RenderDevice, @unchecked Sendable {
        let context: SAGAContext
        weak var windows: (any SAGAWindowProvider)?

        public var supportsFloat32TextureFiltering: Bool { context.capabilities.features.contains(.float32Filterable) }

        // The browser path starts without the optional GPU-driven features of the native backend.
        public var supportsInstancedVertexInputs: Bool { true }
        public var supportsSpatialUpscaling: Bool { false }
        public var supportsTemporalUpscaling: Bool { false }
        /// Hybrid reflections write five HDR targets (40 bytes per pixel) and the surface buffer a sixth. Vulkan has no
        /// per-sample byte limit, so native Vulkan only needs the attachment count. Browsers keep WebGPU's 32-byte limit
        /// and Metal is unverified, so both stay off.
        private var supportsWideGeometryTargets: Bool {
            #if SAGA_NATIVE
                context.capabilities.maxColorAttachments >= 6
            #else
                false
            #endif
        }

        public var supportsHybridReflections: Bool { supportsWideGeometryTargets }
        public var supportsLightingSurfaceBuffer: Bool { supportsWideGeometryTargets }
        public var supportsMultiDrawIndirect: Bool { false }

        init(context: SAGAContext) {
            self.context = context
        }

        public func createBuffer(label: String?, length: Int, options _: ResourceOptions) -> any Buffer {
            SAGABuffer(context: context, label: label, length: length, usage: ResourceOptions.storageShared.sagaUsage)
        }

        public func createBuffer(label: String?, bytes: UnsafeRawPointer, length: Int, options: ResourceOptions) -> any Buffer {
            let buffer = createBuffer(label: label, length: length, options: options)
            unsafe buffer.setData(UnsafeMutableRawPointer(mutating: bytes), byteCount: length, offset: 0)
            return buffer
        }

        public func createIndexBuffer(label: String?, format: IndexBufferFormat, bytes: UnsafeRawPointer, length: Int) -> any IndexBuffer {
            let buffer = SAGAIndexBuffer(context: context, label: label, format: format, length: length)
            unsafe buffer.setData(UnsafeMutableRawPointer(mutating: bytes), byteCount: length, offset: 0)
            return buffer
        }

        public func createVertexBuffer(label: String?, length: Int, binding: Int) -> any VertexBuffer {
            SAGAVertexBuffer(context: context, label: label, length: length, binding: binding)
        }

        public func createUniformBuffer(length: Int, binding: Int) -> any UniformBuffer {
            SAGAUniformBuffer(context: context, length: length, binding: binding)
        }

        public func createUniformBufferSet() -> any UniformBufferSet {
            unsafe GenericUniformBufferSet(frames: RenderEngine.configurations.maxFramesInFlight, device: self)
        }

        public func compileShader(from shader: Shader) throws -> any CompiledShader {
            try SAGAShader(shader: shader, output: context.shaderOutput)
        }

        public func createRenderPipeline(from descriptor: RenderPipelineDescriptor) -> any RenderPipeline {
            do {
                return try SAGARenderPipeline(context: context, descriptor: descriptor)
            } catch {
                preconditionFailure("Failed to create SAGA render pipeline \(descriptor.debugName): \(error)")
            }
        }

        public func createSampler(from descriptor: SamplerDescriptor) -> any Sampler {
            SAGASampler(context: context, descriptor: descriptor)
        }

        public func createTexture(from descriptor: TextureDescriptor) -> any GPUTexture {
            do {
                return try SAGAGPUTexture(context: context, descriptor: descriptor)
            } catch {
                preconditionFailure("Failed to create SAGA texture \(descriptor.debugLabel ?? ""): \(error)")
            }
        }

        public func getImage(from _: Texture) -> Image? {
            // Readback is asynchronous; use `readImage(from:)`.
            nil
        }

        public func readImage(from texture: Texture) async throws -> Image? {
            try await (texture.gpuTexture as? SAGAGPUTexture)?.readImage()
        }

        public func createCommandQueue() -> any CommandQueue {
            SAGACommandQueue(context: context)
        }

        @MainActor
        public func createSwapchain(from window: WindowID) -> (any Swapchain)? {
            guard let window = windows?.window(for: window) else { return nil }
            return SAGASwapchain(window: window)
        }
    }
#endif
