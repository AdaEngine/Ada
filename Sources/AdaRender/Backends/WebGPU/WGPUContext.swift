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
        let spatialScaler = WGPUFSRSpatialScaler()
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
                    let getContext: ((any ConvertibleToJSValue...) -> JSValue) = browserSurface.canvas.getContext,
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
                    scaleFactor: surface.scaleFactor,
                    surfaceOwner: surface,
                    device: device
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
                    guard window.size != newSize || (scaleFactor ?? window.scaleFactor) != window.scaleFactor else {
                        return
                    }
                    #if !WASM
                    if window.acquiredDrawableCount > 0 {
                        // Configuring invalidates the current surface texture.
                        // The render actor may still be encoding that frame.
                        window.pendingSurfaceConfiguration = .init(
                            size: newSize,
                            scaleFactor: scaleFactor ?? window.scaleFactor,
                            pixelFormat: pixelFormat ?? window.pixelFormat
                        )
                    } else {
                        window.pendingSurfaceConfiguration = nil
                        webGPUDeviceLock.withLock { _ in
                            configureSurface(
                                surface: window.surface,
                                size: newSize,
                                scaleFactor: scaleFactor ?? window.scaleFactor,
                                pixelFormat: pixelFormat ?? window.pixelFormat
                            )
                        }
                    }
                    #else
                    webGPUDeviceLock.withLock { _ in
                        configureSurface(
                            surface: window.surface,
                            size: newSize,
                            scaleFactor: scaleFactor ?? window.scaleFactor,
                            pixelFormat: pixelFormat ?? window.pixelFormat
                        )
                    }
                    #endif
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
                guard let window = $0[windowId] else {
                    throw ContextError.windowNotFound
                }
                window.surfaceLock.withLock { _ in
                    window.isActive = false
                    #if !WASM
                    window.pendingSurfaceConfiguration = nil
                    if window.acquiredDrawableCount == 0 {
                        webGPUDeviceLock.withLock { _ in window.surface.unconfigure() }
                    }
                    #endif
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
                renderWindows[windowId] = window.surfaceLock.withLock { _ in
                    AdaRender.RenderWindow(
                        windowId: window.windowId,
                        height: window.size.height,
                        width: window.size.width,
                        scaleFactor: window.scaleFactor
                    )
                }
            }

            return AdaRender.RenderWindows(windows: renderWindows)
        }

        private func configureSurface(
            surface: WGPUSurfaceHandle,
            size: Math.SizeInt,
            scaleFactor: Float,
            pixelFormat: PixelFormat
        ) {
            Self.configureSurface(surface: surface, device: device, size: size, scaleFactor: scaleFactor, pixelFormat: pixelFormat)
        }

        private static func configureSurface(
            surface: WGPUSurfaceHandle,
            device: WebGPU.GPUDevice,
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
                var presentMode: WebGPU.GPUPresentMode = .fifo
                if unsafe RenderEngine.presentationMode == .uncapped,
                   let adapter = (RenderEngine.shared?.renderDevice as? WebGPURenderDevice)?.context.adapter {
                    // Dawn owns these output arrays. The generated Swift wrapper
                    // supplies pointers to empty input arrays, which Dawn rejects.
                    var capabilities = WebGPU.GPUSurfaceCapabilities.WGPUType()
                    defer { WebGPU.wgpuSurfaceCapabilitiesFreeMembers(capabilities) }
                    if surface.getCapabilities(adapter: adapter, capabilities: &capabilities) == .success {
                        let modes = UnsafeBufferPointer(start: capabilities.presentModes, count: capabilities.presentModeCount)
                        if modes.contains(.immediate) { presentMode = .immediate }
                        else if modes.contains(.mailbox) { presentMode = .mailbox }
                    }
                }
                surface.configure(
                    config: WebGPU.GPUSurfaceConfiguration(
                        device: device,
                        format: pixelFormat.toWebGPU,
                        usage: [.renderAttachment, .copySrc],
                        width: UInt32(physicalWidth),
                        height: UInt32(physicalHeight),
                        viewFormats: [],
                        alphaMode: .auto,
                        presentMode: presentMode
                    )
                )
            #endif
        }

        public final class WGPURenderWindow: @unchecked Sendable {
            public let windowId: WindowID
            let surface: WGPUSurfaceHandle
            public let pixelFormat: PixelFormat
            let surfaceLock = Mutex(())
            // Retains the platform surface/ANativeWindow lease across render jobs.
            let surfaceOwner: any RenderSurface
            var isActive = true
            var pendingDrawableSkips: Int = 0
            public var size: Math.SizeInt
            public var scaleFactor: Float
            private let device: WebGPU.GPUDevice
            #if !WASM
            struct SurfaceConfiguration: Sendable {
                let size: Math.SizeInt
                let scaleFactor: Float
                let pixelFormat: PixelFormat
            }
            // All frame lifetime and configuration state uses surfaceLock.
            var acquiredDrawableCount = 0
            var pendingSurfaceConfiguration: SurfaceConfiguration?

            func applyPendingSurfaceConfiguration() {
                guard acquiredDrawableCount == 0, let pendingSurfaceConfiguration else { return }
                webGPUDeviceLock.withLock { _ in
                    WGPUContext.configureSurface(
                        surface: surface, device: device,
                        size: pendingSurfaceConfiguration.size, scaleFactor: pendingSurfaceConfiguration.scaleFactor,
                        pixelFormat: pendingSurfaceConfiguration.pixelFormat
                    )
                }
                self.pendingSurfaceConfiguration = nil
            }

            func finishDrawable() {
                surfaceLock.withLock { _ in
                    acquiredDrawableCount -= 1
                    if !isActive, acquiredDrawableCount == 0 {
                        webGPUDeviceLock.withLock { _ in surface.unconfigure() }
                    }
                }
            }
            #endif

            init(
                windowId: WindowID,
                surface: WGPUSurfaceHandle,
                pixelFormat: PixelFormat,
                size: Math.SizeInt,
                scaleFactor: Float,
                surfaceOwner: any RenderSurface,
                device: WebGPU.GPUDevice
            ) {
                self.windowId = windowId
                self.surface = surface
                self.pixelFormat = pixelFormat
                self.size = size
                self.scaleFactor = scaleFactor
                self.surfaceOwner = surfaceOwner
                self.device = device
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
                #elseif os(Android)
                    guard let androidSurface = self as? AndroidNativeWindowRenderSurface else {
                        preconditionFailure("Android WebGPU needs an Android native window surface")
                    }
                    surfaceDescriptor.nextInChain = unsafe WebGPU.GPUSurfaceSourceAndroidNativeWindow(window: androidSurface.nativeWindow)
                #elseif os(Linux)
                    guard let surface = self as? any LinuxXlibRenderSurface else {
                        preconditionFailure("Linux WebGPU requires an Xlib window surface.")
                    }
                    surfaceDescriptor.nextInChain = unsafe WebGPU.GPUSurfaceSourceXlibWindow(
                        display: surface.xlibDisplay,
                        window: surface.xlibWindow
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
