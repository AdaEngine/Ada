//
//  HeadlessRenderBackend.swift
//  AdaEngine
//

import AdaUtils
import Math

final class HeadlessRenderBackend: RenderBackend, @unchecked Sendable {
    let renderDevice: RenderDevice = HeadlessRenderDevice()
    private var windows = SparseSet<WindowID, RenderWindow>()

    var type: RenderBackendType {
        .headless
    }

    func createLocalRenderDevice() -> RenderDevice {
        HeadlessRenderDevice()
    }

    @MainActor
    func createWindow(_ windowId: WindowID, for surface: RenderSurface, size: SizeInt) throws {
        windows.insert(
            RenderWindow(
                windowId: windowId,
                height: size.height,
                width: size.width,
                scaleFactor: surface.scaleFactor
            ),
            for: windowId
        )
    }

    @MainActor
    func resizeWindow(_ windowId: WindowID, newSize: SizeInt) throws {
        guard var window = windows.firstValue(for: windowId) else {
            return
        }
        window.width = newSize.width
        window.height = newSize.height
        windows.insert(window, for: windowId)
    }

    @MainActor
    func destroyWindow(_ windowId: WindowID) throws {
        windows.remove(for: windowId)
    }

    @MainActor
    func getRenderWindow(for windowId: WindowID) -> RenderWindow? {
        windows.firstValue(for: windowId)
    }

    @MainActor
    func getRenderWindows() throws -> RenderWindows {
        RenderWindows(windows: windows)
    }
}

private final class HeadlessRenderDevice: RenderDevice, @unchecked Sendable {
    func createBuffer(label: String?, length: Int, options _: ResourceOptions) -> Buffer {
        HeadlessBuffer(label: label, length: length)
    }

    func createBuffer(label: String?, bytes: UnsafeRawPointer, length: Int, options _: ResourceOptions) -> Buffer {
        let buffer = HeadlessBuffer(label: label, length: length)
        buffer.setData(UnsafeMutableRawPointer(mutating: bytes), byteCount: length, offset: 0)
        return buffer
    }

    func createIndexBuffer(label: String?, format: IndexBufferFormat, bytes: UnsafeRawPointer, length: Int) -> IndexBuffer {
        let buffer = HeadlessIndexBuffer(label: label, length: length, indexFormat: format)
        buffer.setData(UnsafeMutableRawPointer(mutating: bytes), byteCount: length, offset: 0)
        return buffer
    }

    func createVertexBuffer(label: String?, length: Int, binding: Int) -> VertexBuffer {
        HeadlessVertexBuffer(label: label, length: length, binding: binding)
    }

    func compileShader(from _: Shader) throws -> any CompiledShader {
        HeadlessCompiledShader()
    }

    func createRenderPipeline(from descriptor: RenderPipelineDescriptor) -> RenderPipeline {
        HeadlessRenderPipeline(descriptor: descriptor)
    }

    func createSampler(from descriptor: SamplerDescriptor) -> Sampler {
        HeadlessSampler(descriptor: descriptor)
    }

    func createUniformBuffer(length: Int, binding: Int) -> UniformBuffer {
        HeadlessUniformBuffer(label: nil, length: length, binding: binding)
    }

    func createTexture(from descriptor: TextureDescriptor) -> GPUTexture {
        HeadlessGPUTexture(descriptor: descriptor)
    }

    func getImage(from texture: Texture) -> Image? {
        (texture.gpuTexture as? HeadlessGPUTexture)?.getImage()
    }

    func createCommandQueue() -> CommandQueue {
        HeadlessCommandQueue()
    }

    @MainActor
    func createSwapchain(from _: WindowID) -> (any Swapchain)? {
        HeadlessSwapchain()
    }
}

@unsafe private class HeadlessBuffer: Buffer, @unchecked Sendable {
    var label: String?
    let length: Int
    private let pointer: UnsafeMutableRawPointer

    init(label: String?, length: Int) {
        self.label = label
        self.length = length
        self.pointer = UnsafeMutableRawPointer.allocate(byteCount: max(length, 1), alignment: 1)
        self.pointer.initializeMemory(as: UInt8.self, repeating: 0, count: max(length, 1))
    }

    deinit {
        pointer.deallocate()
    }

    func setData(_ bytes: UnsafeMutableRawPointer, byteCount: Int, offset: Int) {
        guard byteCount > 0, offset < length else {
            return
        }
        pointer.advanced(by: offset).copyMemory(from: bytes, byteCount: min(byteCount, length - offset))
    }

    func contents() -> UnsafeMutableRawPointer {
        pointer
    }

    func unmap() {}
}

private final class HeadlessIndexBuffer: HeadlessBuffer, IndexBuffer {
    let indexFormat: IndexBufferFormat

    init(label: String?, length: Int, indexFormat: IndexBufferFormat) {
        self.indexFormat = indexFormat
        super.init(label: label, length: length)
    }
}

private final class HeadlessVertexBuffer: HeadlessBuffer, VertexBuffer {
    let binding: Int

    init(label: String?, length: Int, binding: Int) {
        self.binding = binding
        super.init(label: label, length: length)
    }
}

private final class HeadlessUniformBuffer: HeadlessBuffer, UniformBuffer {
    let binding: Int

    init(label: String?, length: Int, binding: Int) {
        self.binding = binding
        super.init(label: label, length: length)
    }
}

private final class HeadlessGPUTexture: GPUTexture, @unchecked Sendable {
    let size: SizeInt
    var label: String?
    private var image: Image?

    init(descriptor: TextureDescriptor) {
        self.size = SizeInt(width: descriptor.width, height: descriptor.height)
        self.label = descriptor.debugLabel
        self.image = descriptor.image
    }

    func replaceRegion(_: RectInt, mipmapLevel _: Int, withBytes _: UnsafeRawPointer, bytesPerRow _: Int) {}

    func getImage() -> Image? {
        self.image
    }
}

private final class HeadlessSampler: Sampler {
    let descriptor: SamplerDescriptor

    init(descriptor: SamplerDescriptor) {
        self.descriptor = descriptor
    }
}

private final class HeadlessCompiledShader: CompiledShader {}

private final class HeadlessRenderPipeline: RenderPipeline {
    let descriptor: RenderPipelineDescriptor

    init(descriptor: RenderPipelineDescriptor) {
        self.descriptor = descriptor
    }
}

private final class HeadlessCommandQueue: CommandQueue {
    func makeCommandBuffer() -> CommandBuffer {
        HeadlessCommandBuffer()
    }
}

private final class HeadlessCommandBuffer: CommandBuffer {
    var label: String?
    private var completedHandlers: [@Sendable () -> Void] = []

    func beginRenderPass(_: RenderPassDescriptor) -> RenderCommandEncoder {
        HeadlessRenderCommandEncoder()
    }

    func beginBlitPass(_: BlitPassDescriptor) -> BlitCommandEncoder {
        HeadlessBlitCommandEncoder()
    }

    func commit() {
        completedHandlers.forEach { $0() }
        completedHandlers.removeAll()
    }

    func addCompletedHandler(_ handler: @escaping @Sendable () -> Void) {
        completedHandlers.append(handler)
    }
}

private class HeadlessCommonCommandEncoder: CommonCommandEncoder {
    func pushDebugName(_: String) {}
    func popDebugName() {}
}

private final class HeadlessBlitCommandEncoder: HeadlessCommonCommandEncoder, BlitCommandEncoder {
    func copyTextureToTexture(
        source _: Texture,
        sourceOrigin _: Origin3D,
        sourceSize _: Size3D,
        sourceMipLevel _: Int,
        sourceSlice _: Int,
        destination _: Texture,
        destinationOrigin _: Origin3D,
        destinationMipLevel _: Int,
        destinationSlice _: Int
    ) {}

    func copyBufferToBuffer(source _: Buffer, sourceOffset _: Int, destination _: Buffer, destinationOffset _: Int, size _: Int) {}

    func copyBufferToTexture(
        source _: Buffer,
        sourceOffset _: Int,
        sourceBytesPerRow _: Int,
        sourceBytesPerImage _: Int,
        sourceSize _: Size3D,
        destination _: Texture,
        destinationOrigin _: Origin3D,
        destinationMipLevel _: Int,
        destinationSlice _: Int
    ) {}

    func copyTextureToBuffer(
        source _: Texture,
        sourceOrigin _: Origin3D,
        sourceMipLevel _: Int,
        sourceSlice _: Int,
        sourceSize _: Size3D,
        destination _: Buffer,
        destinationOffset _: Int,
        destinationBytesPerRow _: Int,
        destinationBytesPerImage _: Int
    ) {}

    func endBlitPass() {}
}

private final class HeadlessRenderCommandEncoder: HeadlessCommonCommandEncoder, RenderCommandEncoder {
    func setRenderPipelineState(_: RenderPipeline) {}
    func setVertexBuffer(_: UniformBuffer, offset _: Int, slot _: Int) {}
    func setVertexBuffer(_: VertexBuffer, offset _: Int, slot _: Int) {}
    func setFragmentBuffer(_: UniformBuffer, offset _: Int, slot _: Int) {}
    func setVertexBuffer<T>(_: BufferData<T>, offset _: Int, slot _: Int) {}
    func setFragmentBuffer<T>(_: BufferData<T>, offset _: Int, slot _: Int) {}
    func setIndexBuffer<T>(_: BufferData<T>, indexFormat _: IndexBufferFormat) {}
    func setVertexBytes(_: UnsafeRawPointer, length _: Int, slot _: Int) {}
    func setFragmentTexture(_: Texture, slot _: Int) {}
    func setFragmentSamplerState(_: Sampler, slot _: Int) {}
    func setResourceSet(_: RenderResourceSet, index _: Int) {}
    func setViewport(_: Rect) {}
    func setScissorRect(_: Rect) {}
    func setTriangleFillMode(_: TriangleFillMode) {}
    func setIndexBuffer(_: IndexBuffer, offset _: Int) {}
    func drawIndexed(indexCount _: Int, indexBufferOffset _: Int, instanceCount _: Int) {}
    func draw(type _: IndexPrimitive, vertexStart _: Int, vertexCount _: Int, instanceCount _: Int) {}
    func endRenderPass() {}
}

private final class HeadlessSwapchain: Swapchain {
    let drawablePixelFormat: PixelFormat = .bgra8

    func getNextDrawable(_: RenderDevice) -> (any Drawable)? {
        nil
    }
}
