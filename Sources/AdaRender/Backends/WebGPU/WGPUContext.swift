//
//  WGPUContext.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 04.01.2026.
//

#if WEBGPU_ENABLED && canImport(WebGPU)
    import AdaUtils
    import Foundation
    import Math
    import Synchronization
    @unsafe @preconcurrency import WebGPU
    #if WASM && canImport(JavaScriptKit)
        import JavaScriptKit
    #endif
    #if canImport(MetalKit)
        import MetalKit
        import QuartzCore
    #endif
    #if os(Windows)
        import WinSDK
    #endif

    let webGPUDeviceLock = Mutex(())

    #if WASM
        typealias WGPUSurfaceHandle = WebGPU.GPUCanvasContext
    #else
        typealias WGPUSurfaceHandle = WebGPU.GPUSurface
    #endif

    public final class WGPUContext: @unchecked Sendable {
        public let device: WebGPU.GPUDevice
        public let adapter: WebGPU.GPUAdapter
        let instance: WebGPU.GPUInstance

        private let windows = Mutex<[WindowID: WGPURenderWindow]>([:])

        init(device: WebGPU.GPUDevice, adapter: WebGPU.GPUAdapter, instance: WebGPU.GPUInstance) {
            self.device = device
            self.adapter = adapter
            self.instance = instance
        }

        @MainActor
        public func createWindow(_ windowId: WindowID, for surface: any RenderSurface, size: Math.SizeInt) throws {
            let existingWindow = self.windows.withLock { $0[windowId] }
            guard existingWindow == nil else {
                throw ContextError.creationWindowAlreadyExists
            }

            #if WASM && canImport(JavaScriptKit)
                guard
                    let browserSurface = surface as? BrowserCanvasRenderSurface,
                    let getContext: (String) -> JSValue = browserSurface.canvas.getContext,
                    let contextObject = getContext("webgpu").object
                else {
                    throw ContextError.invalidSurface
                }
                let wgpuSurface = WebGPU.GPUCanvasContext(unsafelyWrapping: contextObject)
            #else
                let surfaceDescriptor = surface.createWebGPUSurface()
                let wgpuSurface = instance.createSurface(descriptor: surfaceDescriptor)
            #endif
            configureSurface(
                surface: wgpuSurface,
                size: size,
                scaleFactor: surface.scaleFactor,
                pixelFormat: surface.prefferedPixelFormat
            )
            storeWindow(
                WGPURenderWindow(
                    windowId: windowId,
                    surface: wgpuSurface,
                    pixelFormat: surface.prefferedPixelFormat,
                    size: size,
                    scaleFactor: surface.scaleFactor
                )
            )
        }

        @MainActor
        public func resizeWindow(_ windowId: WindowID, newSize: Math.SizeInt) throws {
            try resizeWindow(windowId, newSize: newSize, scaleFactor: nil)
        }

        @MainActor
        public func resizeWindow(_ windowId: WindowID, newSize: Math.SizeInt, scaleFactor: Float) throws {
            try resizeWindow(windowId, newSize: newSize, scaleFactor: scaleFactor as Float?)
        }

        @MainActor
        private func resizeWindow(_ windowId: WindowID, newSize: Math.SizeInt, scaleFactor: Float?) throws {
            guard newSize.width > 0 && newSize.height > 0 else {
                return
            }

            try resizeStoredWindow(
                windowId,
                newSize: newSize,
                scaleFactor: scaleFactor,
                pixelFormat: nil
            )
        }

        private func storeWindow(_ window: WGPURenderWindow) {
            self.windows.withLock { windows in
                windows[window.windowId] = window
            }
        }

        private func resizeStoredWindow(
            _ windowId: WindowID,
            newSize: Math.SizeInt,
            scaleFactor: Float?,
            pixelFormat: PixelFormat?
        ) throws {
            try self.windows.withLock { windows in
                guard let window = windows[windowId] else {
                    throw ContextError.windowNotFound
                }
                window.surfaceLock.withLock { _ in
                    webGPUDeviceLock.withLock { _ in
                        configureSurface(
                            surface: window.surface,
                            size: newSize,
                            scaleFactor: scaleFactor ?? window.scaleFactor,
                            pixelFormat: pixelFormat ?? window.pixelFormat
                        )
                    }
                    window.size = newSize
                    if let scaleFactor {
                        window.scaleFactor = scaleFactor
                    }
                    #if !WASM
                        window.pendingDrawableSkips = 2
                    #endif
                }
                windows[windowId] = window
            }
        }

        public func destroyWindow(_ windowId: WindowID) throws {
            try self.windows.withLock {
                guard $0[windowId] != nil else {
                    throw ContextError.windowNotFound
                }
                $0.removeValue(forKey: windowId)
            }
        }

        public func getRenderWindow(for windowId: WindowID) -> AdaRender.RenderWindow? {
            self.windows.withLock { windows in
                guard let window = windows[windowId] else {
                    return nil
                }
                return AdaRender.RenderWindow(
                    windowId: window.windowId,
                    height: window.size.height,
                    width: window.size.width,
                    scaleFactor: window.scaleFactor
                )
            }
        }

        @inline(__always)
        public func getWGPURenderWindow(for windowId: WindowID) -> WGPURenderWindow? {
            self.windows.withLock { windows in
                return windows[windowId]
            }
        }

        public func getRenderWindows() throws -> AdaRender.RenderWindows {
            let windows = self.windows.withLock { $0 }
            var renderWindows = SparseSet<WindowID, AdaRender.RenderWindow>()
            for (windowId, window) in windows {
                renderWindows[windowId] = AdaRender.RenderWindow(
                    windowId: window.windowId,
                    height: window.size.height,
                    width: window.size.width,
                    scaleFactor: window.scaleFactor
                )
            }

            return AdaRender.RenderWindows(windows: renderWindows)
        }

        private func configureSurface(
            surface: WGPUSurfaceHandle,
            size: Math.SizeInt,
            scaleFactor: Float,
            pixelFormat: PixelFormat
        ) {
            #if WASM
                surface.configure(
                    configuration: WebGPU.GPUCanvasConfiguration(
                        device: device,
                        format: pixelFormat.toWebGPU
                    )
                )
            #else
                let physicalWidth = max(Int((Float(size.width) * scaleFactor).rounded()), 1)
                let physicalHeight = max(Int((Float(size.height) * scaleFactor).rounded()), 1)
                surface.configure(
                    config: WebGPU.GPUSurfaceConfiguration(
                        device: device,
                        format: pixelFormat.toWebGPU,
                        usage: [.renderAttachment, .copySrc],
                        width: UInt32(physicalWidth),
                        height: UInt32(physicalHeight),
                        viewFormats: [],
                        alphaMode: .auto,
                        presentMode: .fifo
                    )
                )
            #endif
        }

        public final class WGPURenderWindow: @unchecked Sendable {
            public let windowId: WindowID
            let surface: WGPUSurfaceHandle
            public let pixelFormat: PixelFormat
            let surfaceLock = Mutex(())
            var pendingDrawableSkips: Int = 0
            public var size: Math.SizeInt
            public var scaleFactor: Float

            init(
                windowId: WindowID,
                surface: WGPUSurfaceHandle,
                pixelFormat: PixelFormat,
                size: Math.SizeInt,
                scaleFactor: Float
            ) {
                self.windowId = windowId
                self.surface = surface
                self.pixelFormat = pixelFormat
                self.size = size
                self.scaleFactor = scaleFactor
            }
        }

        enum ContextError: LocalizedError {
            case creationWindowAlreadyExists
            case windowNotFound
            case invalidSurface
            case platformNotSupported

            var errorDescription: String? {
                switch self {
                case .creationWindowAlreadyExists:
                    return "WebGPURenderWindow Creation Failed: Window by given id already exists."
                case .windowNotFound:
                    return "WebGPURenderWindow: Window not found."
                case .invalidSurface:
                    return "WebGPURenderWindow: Invalid surface provided."
                case .platformNotSupported:
                    return "WebGPURenderWindow: Platform not supported."
                }
            }
        }
    }

    #if !WASM
        extension RenderSurface {
            @MainActor
            func createWebGPUSurface() -> WebGPU.GPUSurfaceDescriptor {
                var surfaceDescriptor = WebGPU.GPUSurfaceDescriptor()

                #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
                    let view = (self as! MTKView)
                    guard let layer = view.layer else {
                        preconditionFailure("Metal-backed WebGPU surfaces require a CAMetalLayer.")
                    }
                    surfaceDescriptor.nextInChain = unsafe WebGPU.GPUSurfaceSourceMetalLayer(
                        layer: Unmanaged.passUnretained(layer).toOpaque()
                    )
                #elseif os(Linux)
                    surfaceDescriptor.nextInChain = unsafe WebGPU.GPUSurfaceSourceXlibWindow(
                        display: UnsafeMutableRawPointer(glfwGetX11Display()),
                        window: UInt64(glfwGetX11Window(handle))
                    )
                #elseif os(Windows)
                    let surface = (self as! WindowsSurface)
                    let hwnd = surface.windowHwnd.assumingMemoryBound(to: HWND__.self)
                    surfaceDescriptor.nextInChain = unsafe WebGPU.GPUSurfaceSourceWindowsHWND(
                        hinstance: UnsafeMutableRawPointer(bitPattern: Int(GetWindowLongPtrW(hwnd, GWLP_HINSTANCE))),
                        hwnd: surface.windowHwnd
                    )
                #endif

                return surfaceDescriptor
            }
        }
    #endif

#endif
