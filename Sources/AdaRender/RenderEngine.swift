//
//  RenderEngine.swift
//  AdaEngine
//
//  Created by v.prusakov on 10/25/21.
//

import AdaUtils
import Foundation
import Math
import OrderedCollections

/// Global information about buffer index.
public enum GlobalBufferIndex {
    public static let viewUniform: Int = 2
}

/// Controls whether the renderer draws at native resolution or upscales a lower-resolution frame.
public enum RenderUpscalingMode: Sendable, Equatable {
    /// Render directly at the output resolution.
    case disabled

    /// Use the backend's spatial upscaler when it is available.
    ///
    /// The scale is clamped to `0.5...1`. Backends without a native spatial
    /// upscaler render at native resolution instead of applying a generic filter.
    case spatial(renderScale: Float)
}

/// Render Engine is object that manage a GPU.
public final class RenderEngine: RenderBackend, Sendable {
    public struct Configuration {
        /// The maximum number of frames in flight.
        public var maxFramesInFlight: Int = 3

        /// The preferred backend to use for rendering.
        public var preferredBackend: RenderBackendType?

        /// The upscaling mode used for window render targets.
        ///
        /// iOS defaults to MetalFX spatial upscaling from 75% linear resolution.
        /// Other platforms keep native resolution unless explicitly configured.
        public var upscaling: RenderUpscalingMode = {
            #if os(iOS)
                .spatial(renderScale: 0.75)
            #else
                .disabled
            #endif
        }()

        public init() {}
    }

    /// Setup configuration for render engine
    nonisolated(unsafe) public static var configurations: Configuration = Configuration()

    /// Return instance of render engine for specific backend.
    nonisolated(unsafe) public private(set) static var shared: RenderEngine!

    private let renderBackend: RenderBackend

    init(renderBackend: RenderBackend) {
        self.renderBackend = renderBackend
    }

    // MARK: - RenderBackend

    public var type: RenderBackendType {
        self.renderBackend.type
    }

    /// Returns global ``RenderDevice``.
    public var renderDevice: RenderDevice {
        return self.renderBackend.renderDevice
    }

    public func createLocalRenderDevice() -> RenderDevice {
        return self.renderBackend.createLocalRenderDevice()
    }

    public func createWindow(_ windowId: WindowID, for surface: RenderSurface, size: SizeInt) throws {
        try self.renderBackend.createWindow(windowId, for: surface, size: size)
    }

    public func resizeWindow(_ windowId: WindowID, newSize: SizeInt) throws {
        try self.renderBackend.resizeWindow(windowId, newSize: newSize)
    }

    @MainActor
    public func resizeWindow(_ windowId: WindowID, newSize: SizeInt, scaleFactor: Float) throws {
        #if WEBGPU_ENABLED && canImport(WebGPU)
            if let webGPUBackend = self.renderBackend as? WebGPURenderBackend {
                try webGPUBackend.resizeWindow(windowId, newSize: newSize, scaleFactor: scaleFactor)
                return
            }
        #endif

        try self.renderBackend.resizeWindow(windowId, newSize: newSize)
    }

    public func destroyWindow(_ windowId: WindowID) throws {
        try self.renderBackend.destroyWindow(windowId)
    }

    func getRenderWindow(for windowId: WindowID) -> RenderWindow? {
        self.renderBackend.getRenderWindow(for: windowId)
    }

    public func getRenderWindows() throws -> RenderWindows {
        try self.renderBackend.getRenderWindows()
    }
}

extension RenderDevice {
    public func createUniformBuffer<T>(_: T.Type, count: Int = 1, binding: Int) -> UniformBuffer {
        self.createUniformBuffer(length: MemoryLayout<T>.stride * count, binding: binding)
    }
}

extension RenderEngine {
    package static func setupRenderEngine() throws {
        // Guard: only the first caller creates the engine; subsequent callers (e.g. SceneView
        // subworld) reuse the existing instance so the main window registration is preserved.
        guard unsafe Self.shared == nil else {
            return
        }
        let preferredBackend = unsafe Self.configurations.preferredBackend ?? Self.defaultBackendType()
        let renderBackend: RenderBackend
        switch preferredBackend {
        case .webgpu:
            #if WEBGPU_ENABLED && canImport(WebGPU)
                renderBackend = try WebGPURenderBackend.createBackend()
            #else
                #if WASM
                    throw RenderEngineSetupError.browserWebGPUBackendUnavailable
                #else
                    fallthrough
                #endif
            #endif
        case .metal:
            #if METAL
                renderBackend = MetalRenderBackend()
            #else
                fallthrough
            #endif
        case .headless:
            renderBackend = HeadlessRenderBackend()
        }
        let engine = RenderEngine(renderBackend: renderBackend)
        unsafe Self.shared = engine
    }

    private static func defaultBackendType() -> RenderBackendType {
        #if WASM
            #if WEBGPU_ENABLED && canImport(WebGPU)
                return .webgpu
            #else
                return .headless
            #endif
        #elseif WEBGPU_ENABLED && canImport(WebGPU)
            return .webgpu
        #elseif METAL
            return .metal
        #else
            return .headless
        #endif
    }
}

private enum RenderEngineSetupError: LocalizedError {
    case browserWebGPUBackendUnavailable

    var errorDescription: String? {
        switch self {
        case .browserWebGPUBackendUnavailable:
            "Browser WebGPU backend is not linked. Add a WASM/browser WebGPU implementation before using RenderWorldPlugin in web exports."
        }
    }
}
