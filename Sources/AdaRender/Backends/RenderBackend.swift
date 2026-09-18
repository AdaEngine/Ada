//
//  RenderBackend.swift
//  AdaEngine
//
//  Created by v.prusakov on 10/9/21.
//

import AdaUtils
import Foundation
import Math

public enum TriangleFillMode {
    case fill
    case lines
}

public enum RenderBackendType: String, Sendable {
    case metal
    case webgpu
    case headless
}

/// This protocol describe interface for GPU.
protocol RenderBackend: AnyObject, Sendable {
    var type: RenderBackendType { get }

    /// Returns global ``RenderDevice``.
    var renderDevice: RenderDevice { get }

    /// Create a local render device, that can render only in texture.
    func createLocalRenderDevice() -> RenderDevice

    /// Register a new render window for render backend.
    /// Window in this case is entity that managed a drawables (aka swapchain).
    /// - Throws: Throw error if something went wrong.
    @MainActor func createWindow(_ windowId: WindowID, for surface: RenderSurface, size: SizeInt) throws

    /// Resize registred render window.
    /// - Throws: Throw error if window is not registred.
    @MainActor func resizeWindow(_ windowId: WindowID, newSize: SizeInt) throws

    /// Destroy render window from render backend.
    /// - Throws: Throw error if window is not registred.
    @MainActor func destroyWindow(_ windowId: WindowID) throws

    @MainActor func getRenderWindow(for windowId: WindowID) -> RenderWindow?

    /// Returns render windows
    @MainActor func getRenderWindows() throws -> RenderWindows
}

/// The GPU device instance resposible for rendering and computing.
public protocol RenderDevice: AnyObject, Sendable {
    /// Returns whether this device can encode a backend-native spatial upscale.
    var supportsSpatialUpscaling: Bool { get }

    // MARK: - Buffers

    /// Create a new GPU buffer with specific length and options.
    func createBuffer(label: String?, length: Int, options: ResourceOptions) -> Buffer

    /// Create a new GPU buffer with specific data, length and options.
    func createBuffer(label: String?, bytes: UnsafeRawPointer, length: Int, options: ResourceOptions) -> Buffer

    /// Create a new index buffer with specific index, format, data and length.
    func createIndexBuffer(label: String?, format: IndexBufferFormat, bytes: UnsafeRawPointer, length: Int) -> IndexBuffer

    /// Create a new vertex buffer for specific length and binding.
    func createVertexBuffer(label: String?, length: Int, binding: Int) -> VertexBuffer

    // MARK: - Shaders

    /// Compile device specific shader from shader data.
    /// - Throws: Throw an error if something went wrong on compilation.
    func compileShader(from shader: Shader) throws -> any CompiledShader

    /// Create pipeline state from shader.
    func createRenderPipeline(from descriptor: RenderPipelineDescriptor) -> RenderPipeline

    /// Create a new GPU sampler from descriptor.
    func createSampler(from descriptor: SamplerDescriptor) -> Sampler

    // MARK: - Uniforms

    /// Create a new uniform buffer with specific length and binding.
    func createUniformBuffer(length: Int, binding: Int) -> UniformBuffer

    // MARK: - Texture

    /// Create a new GPU Texture from descriptor.
    func createTexture(from descriptor: TextureDescriptor) -> GPUTexture

    /// Get image from texture rid.
    func getImage(from texture: Texture) -> Image?

    func createCommandQueue() -> CommandQueue

    /// Create a new swapchain for specific window.
    @MainActor
    func createSwapchain(from window: WindowID) -> (any Swapchain)?
}

public protocol Swapchain: AnyObject, Sendable {
    var drawablePixelFormat: PixelFormat { get }
    func getNextDrawable(_ renderDevice: RenderDevice) -> (any Drawable)?
}

public protocol Drawable: AnyObject, Sendable {
    var texture: any GPUTexture { get }
    func present() throws
}

extension RenderDevice {
    public var supportsSpatialUpscaling: Bool { false }

    /// Create a new GPU buffer with specific length and options.
    @inline(__always)
    public func createBuffer(length: Int, options: ResourceOptions) -> Buffer {
        createBuffer(label: nil, length: length, options: options)
    }

    /// Create a new GPU buffer with specific data, length and options.
    @inline(__always)
    public func createBuffer(bytes: UnsafeRawPointer, length: Int, options: ResourceOptions) -> Buffer {
        unsafe createBuffer(label: nil, bytes: bytes, length: length, options: options)
    }

    /// Create a new index buffer with specific index, format, data and length.
    @inline(__always)
    public func createIndexBuffer(format: IndexBufferFormat, bytes: UnsafeRawPointer, length: Int) -> IndexBuffer {
        unsafe createIndexBuffer(label: nil, format: format, bytes: bytes, length: length)
    }

    /// Create a new vertex buffer for specific length and binding.
    @inline(__always)
    public func createVertexBuffer(length: Int, binding: Int) -> VertexBuffer {
        createVertexBuffer(label: nil, length: length, binding: binding)
    }
}

enum DrawListError: String, LocalizedError {
    case notAGlobalDevice = "RenderDevice isn't a global."
    case windowNotExists = "Required window doesn't exists."
    case failedToGetSurfaceTexture = "Failed to get surface texture."
    case failedToCreateCommandBuffer = "Failed to create command buffer"
    case failedToGetRenderPass = "Cannot get a render pass descriptor for current draw"

    var errorDescription: String? {
        return self.rawValue
    }
}
