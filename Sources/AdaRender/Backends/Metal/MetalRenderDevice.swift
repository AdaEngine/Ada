//
//  MetalRenderDevice.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 29.08.2024.
//

#if METAL
    import AdaUtils
    import Math
    import Metal
    #if canImport(MetalFX) && (os(macOS) || os(iOS))
        @unsafe @preconcurrency import MetalFX
    #endif
    @unsafe @preconcurrency import MetalKit
    import QuartzCore
    import Synchronization
    import Tracing

    final class MetalRenderDevice: RenderDevice, @unchecked Sendable {
        var supportsSpatialUpscaling: Bool {
            #if canImport(MetalFX) && (os(macOS) || os(iOS))
                MTLFXSpatialScalerDescriptor.supportsDevice(device)
            #else
                false
            #endif
        }

        let device: MTLDevice
        let commandQueue: MTLCommandQueue
        private weak var context: MetalRenderBackend.Context?

        init(
            device: MTLDevice,
            commandQueue: MTLCommandQueue,
            context: MetalRenderBackend.Context? = nil
        ) {
            self.device = device
            self.commandQueue = commandQueue
            self.context = context
        }

        func compileShader(from shader: Shader) throws -> CompiledShader {
            return try MetalShader(shader: shader, device: self.device)
        }

        func createCommandQueue() -> CommandQueue {
            return MetalCommandQueue(commandQueue: self.commandQueue)
        }

        func createRenderPipeline(from descriptor: RenderPipelineDescriptor) -> RenderPipeline {
            do {
                return try MetalRenderPipeline(descriptor: descriptor, device: device)
            } catch {
                fatalError("[Metal Render Backend] \(error)")
            }
        }

        func createSampler(from descriptor: SamplerDescriptor) -> Sampler {
            return MetalSampler(descriptor: descriptor, device: device)
        }

        // MARK: - Buffers

        func createIndexBuffer(label: String?, format: IndexBufferFormat, bytes: UnsafeRawPointer, length: Int) -> IndexBuffer {
            let buffer = self.device.makeBuffer(length: length, options: .storageModeShared)
                .unwrap(message: "Metal failed to allocate an index buffer of \(length) bytes.")
            unsafe buffer.contents().copyMemory(from: bytes, byteCount: length)
            let metalBuffer = MetalIndexBuffer(buffer: buffer, indexFormat: format)
            metalBuffer.label = label
            return metalBuffer
        }

        func createVertexBuffer(label: String?, length: Int, binding _: Int) -> VertexBuffer {
            let buffer = self.device.makeBuffer(length: length, options: .storageModeShared)
                .unwrap(message: "Metal failed to allocate a vertex buffer of \(length) bytes.")
            let metalBuffer = MetalVertexBuffer(buffer: buffer, binding: 0, offset: 0)
            metalBuffer.label = label
            return metalBuffer
        }

        func createBuffer(label: String?, length: Int, options: ResourceOptions) -> Buffer {
            let buffer = self.device.makeBuffer(length: length, options: options.metal)
                .unwrap(message: "Metal failed to allocate a buffer of \(length) bytes.")
            let metalBuffer = MetalBuffer(buffer: buffer)
            metalBuffer.label = label
            return metalBuffer
        }

        func createBuffer(label: String?, bytes: UnsafeRawPointer, length: Int, options: ResourceOptions) -> Buffer {
            let buffer = unsafe self.device.makeBuffer(bytes: bytes, length: length, options: options.metal)
                .unwrap(message: "Metal failed to allocate a populated buffer of \(length) bytes.")
            let metalBuffer = MetalBuffer(buffer: buffer)
            metalBuffer.label = label
            return metalBuffer
        }

        @MainActor
        func createSwapchain(from window: WindowID) -> (any Swapchain)? {
            guard let context else {
                fatalError("Context not found")
            }
            guard let window = context.getRenderWindow(for: window) else {
                return nil
            }

            return MetalViewSwapchain(view: window.view)
        }
    }

    private final class MetalViewSwapchain: Swapchain, @unchecked Sendable {
        private let metalLayer: CAMetalLayer
        private let pixelFormat: PixelFormat

        @MainActor
        init(view: MTKView) {
            guard let layer = view.layer as? CAMetalLayer else {
                fatalError("MTKView must be backed by CAMetalLayer")
            }
            self.metalLayer = layer
            self.pixelFormat = view.colorPixelFormat.toPixelFormat()
        }

        var drawablePixelFormat: PixelFormat {
            pixelFormat
        }

        func getNextDrawable(_ renderDevice: RenderDevice) -> (any Drawable)? {
            guard
                let drawable = metalLayer.nextDrawable(),
                let mtlDevice = renderDevice as? MetalRenderDevice
            else {
                return nil
            }
            return MetalDrawable(drawable: drawable, commandQueue: mtlDevice.commandQueue)
        }
    }

    extension MTLPixelFormat {
        func toPixelFormat() -> PixelFormat {
            switch self {
            case .bgra8Unorm:
                return .bgra8
            case .bgra8Unorm_srgb:
                return .bgra8_srgb
            case .rgba8Unorm:
                return .rgba8
            case .rgba8Uint:
                return .rgba8
            case .rgba16Float:
                return .rgba_16f
            case .rgba32Float:
                return .rgba_32f
            case .depth32Float:
                return .depth_32f
            case .depth32Float_stencil8:
                return .depth_32f_stencil8
            default:
                fatalError("Unsupported pixel format: \(self)")
            }
        }
    }

    final class MetalDrawable: Drawable, @unchecked Sendable {
        private static let previousPresentedTime = Mutex<CFTimeInterval?>(nil)

        private let commandQueue: MTLCommandQueue
        private let mtlDrawable: CAMetalDrawable
        private let isPresented = Mutex(false)

        public var texture: any GPUTexture {
            MetalGPUTexture(texture: self.mtlDrawable.texture)
        }

        public func present() throws {
            let alreadyPresented = isPresented.withLock { value in
                if value {
                    return true
                }
                value = true
                return false
            }
            guard !alreadyPresented else {
                return
            }
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                return
            }
            let span = AdaTrace.startSpan(
                lazyName: "Display.present",
                attributes: [
                    "ada.profile.category": "display",
                    "ada.display.submitted_time": .double(CACurrentMediaTime()),
                ]
            )
            #if os(macOS)
                if span.isRecording {
                    span.attributes["ada.display.drawable_id"] = Int64(mtlDrawable.drawableID)
                }
                mtlDrawable.addPresentedHandler { drawable in
                    let presentedTime = drawable.presentedTime
                    var interval: CFTimeInterval?
                    // Keep cadence history current even while detailed tracing is off,
                    // so resuming recording does not report the idle recording gap as a dropped frame.
                    if presentedTime > 0 {
                        interval = Self.previousPresentedTime.withLock { previousTime -> CFTimeInterval? in
                            defer { previousTime = presentedTime }
                            return previousTime.map { presentedTime - $0 }
                        }
                    }
                    guard span.isRecording else {
                        return
                    }
                    var attributes = span.attributes
                    attributes["ada.display.presented_time"] = presentedTime
                    attributes["ada.display.dropped"] = presentedTime == 0
                    if let interval {
                        attributes["ada.display.interval_ms"] = interval * 1_000
                    }
                    span.attributes = attributes
                    span.end()
                }
            #else
                commandBuffer.addCompletedHandler { _ in
                    span.end()
                }
            #endif
            commandBuffer.label = "(AdaRender internal) Present"
            commandBuffer.present(self.mtlDrawable)
            commandBuffer.commit()
        }

        init(drawable: CAMetalDrawable, commandQueue: MTLCommandQueue) {
            self.commandQueue = commandQueue
            self.mtlDrawable = drawable
        }
    }

    // MARK: Texture

    extension MetalRenderDevice {
        func createTexture(from descriptor: TextureDescriptor) -> GPUTexture {
            return MetalGPUTexture(descriptor: descriptor, device: self.device)
        }

        func getImage(from texture: Texture) -> Image? {
            (texture.gpuTexture as? MetalGPUTexture)?.getImage()
        }
    }

    // MARK: - Drawings

    extension MetalRenderDevice {
        func createUniformBufferSet() -> UniformBufferSet {
            return unsafe GenericUniformBufferSet(frames: RenderEngine.configurations.maxFramesInFlight, device: self)
        }

        func createUniformBuffer(length: Int, binding: Int) -> UniformBuffer {
            // Metal requires uniform buffers to be aligned to 16 bytes for proper struct alignment
            let alignedLength = (length + 15) & ~15
            let buffer = self.device.makeBuffer(
                length: alignedLength,
                options: .storageModeShared
            ).unwrap(message: "Metal failed to allocate a uniform buffer of \(alignedLength) bytes.")

            let uniformBuffer = MetalUniformBuffer(buffer: buffer, binding: binding)
            return uniformBuffer
        }
    }

#endif
