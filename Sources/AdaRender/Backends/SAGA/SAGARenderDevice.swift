//
//  SAGARenderDevice.swift
//  AdaEngine
//

#if SAGA_RENDER && canImport(SAGACompiler)
    import AdaUtils
    import Foundation
    import Logging
    import Math
    import SAGA
    import SAGACore
    import SAGATypes
    import Synchronization

    @_spi(Internal)
    public final class SAGARenderDevice: RenderDevice, RenderDeviceWithCommandCompletion, @unchecked Sendable {
        let context: SAGAContext
        weak var windows: (any SAGAWindowProvider)?

        public var supportsFloat32TextureFiltering: Bool { context.capabilities.features.contains(.float32Filterable) }

        // The browser path starts without the optional GPU-driven features of the native backend.
        public var supportsInstancedVertexInputs: Bool { true }
        public var supportsSpatialUpscaling: Bool { false }
        public var supportsTemporalUpscaling: Bool { dlssStatus.isAvailable }
        #if SAGA_NATIVE
            /// Probed once: discovery touches the file system and the result cannot change while the process runs.
            public var dlssStatus: DLSSRuntimeStatus {
                #if os(Windows)
                    context.dlssSession.withLock { $0 }?.status ?? .unavailable(reason: "DLSS is not set up for this renderer")
                #else
                    .unavailable(reason: "DLSS needs the Vulkan renderer")
                #endif
            }
        #endif
        /// The combined geometry pass writes five RGBA16Float targets and one RGBA8Unorm surface target.
        /// SAGA's attachment budget charges eight bytes per sample for each of those formats.
        private var supportsWideGeometryTargets: Bool {
            #if SAGA_NATIVE || SAGA_METAL
                context.capabilities.maxColorAttachments >= 6
                    && context.capabilities.maxColorAttachmentBytesPerSample >= 48
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

        #if SAGA_NATIVE || SAGA_METAL
        /// Hardware ray queries are verified on the Vulkan backend only; Metal reports false until it has coverage.
        public var supportsRayQueries: Bool {
            #if SAGA_NATIVE
                context.capabilities.features.contains(.rayQuery)
            #else
                false
            #endif
        }

        public func createAccelerationStructure(_ kind: AccelerationStructureKind) -> (any AccelerationStructure)? {
            guard supportsRayQueries else { return nil }
            return SAGAAccelerationStructure(context: context, kind: kind)
        }

        public func createTemporalUpscaler(inputSize: SizeInt, outputSize: SizeInt) -> (any TemporalUpscaler)? {
            #if SAGA_NATIVE && os(Windows) && canImport(SAGAVulkan)
                guard let session = context.dlssSession.withLock({ $0 }) else { return nil }
                return SAGADLSSUpscaler(session: session, context: context, inputSize: inputSize, outputSize: outputSize)
            #else
                return nil
            #endif
        }

        public func createGPUVisibilityProcessor() -> (any GPUVisibilityProcessor)? {
            do {
                return try SAGAVisibilityProcessor(context: context)
            } catch {
                context.logger.error("Cannot compile SAGA visibility shaders: \(error)")
                return nil
            }
        }
        #endif

        @MainActor
        public func createSwapchain(from window: WindowID) -> (any Swapchain)? {
            guard let window = windows?.window(for: window) else { return nil }
            return SAGASwapchain(window: window)
        }
    }
#endif
