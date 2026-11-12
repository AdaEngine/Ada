//
//  SAGARenderBackend.swift
//  AdaEngine
//
//  Browser render backend on top of SAGA (see Documentation/Designs/saga-migration.md).
//

#if SAGA_WEBGPU && canImport(SAGAWebHost) && canImport(JavaScriptKit) && canImport(SAGACompiler)
    import AdaUtils
    import Foundation
    import JavaScriptKit
    import Math
    import SAGA
    import SAGACore
    import SAGATypes
    import SAGAWebHost
    import Synchronization

    @_spi(Internal)
    public final class SAGARenderBackend: RenderBackend, SAGAWindowProvider, @unchecked Sendable {
        enum SetupError: LocalizedError {
            case missingHost

            var errorDescription: String? {
                "The page did not provide `__adaSAGAHost`. Open the SAGA WebGPU host (`openWebGPU`) before starting the engine."
            }
        }

        let context: SAGAContext
        private let device: SAGARenderDevice
        private let windows = Mutex<[WindowID: SAGAWindow]>([:])

        var type: RenderBackendType { .webgpu }
        var renderDevice: RenderDevice { device }

        private let host: JSObject

        init(context: SAGAContext, host: JSObject) {
            self.host = host
            self.context = context
            self.device = SAGARenderDevice(context: context)
            self.device.windows = self
        }

        static func createBackend() throws -> SAGARenderBackend {
            guard let host = JSObject.global.__adaSAGAHost.object else {
                throw SetupError.missingHost
            }
            let parameters = WebHostParameters(host: host)
            let capabilities = try makeWebDeviceCapabilities(parameters)
            let context = SAGAContext(
                capabilities: capabilities,
                supportsPresentation: parameters.presentation != 0,
                debugErrors: JSObject.global.__adaSAGADebug.boolean == true,
                transport: JSBrowserTransport(host: host)
            )
            return SAGARenderBackend(context: context, host: host)
        }

        func createLocalRenderDevice() -> RenderDevice {
            SAGARenderDevice(context: context)
        }

        @MainActor
        func createWindow(_ windowId: WindowID, for surface: RenderSurface, size: SizeInt) throws {
            if let canvasSurface = surface as? BrowserCanvasRenderSurface {
                // The host presents into the canvas of the first window it is given.
                _ = host.attachCanvas?(canvasSurface.canvas)
            }
            let window = SAGAWindow(
                context: context,
                windowId: windowId,
                size: size,
                scaleFactor: surface.scaleFactor,
                pixelFormat: surface.prefferedPixelFormat
            )
            windows.withLock { $0[windowId] = window }
        }

        @MainActor
        func resizeWindow(_ windowId: WindowID, newSize: SizeInt) throws {
            windows.withLock { $0[windowId] }?.resize(to: newSize)
        }

        @MainActor
        func resizeWindow(_ windowId: WindowID, newSize: SizeInt, scaleFactor: Float) throws {
            windows.withLock { $0[windowId] }?.resize(to: newSize, scaleFactor: scaleFactor)
        }

        @MainActor
        func destroyWindow(_ windowId: WindowID) throws {
            windows.withLock { _ = $0.removeValue(forKey: windowId) }
        }

        @MainActor
        func getRenderWindow(for windowId: WindowID) -> RenderWindow? {
            windows.withLock { $0[windowId] }?.renderWindow
        }

        @MainActor
        func getRenderWindows() throws -> RenderWindows {
            var set = SparseSet<WindowID, RenderWindow>()
            for (id, window) in windows.withLock({ $0 }) {
                set.insert(window.renderWindow, for: id)
            }
            return RenderWindows(windows: set)
        }

        func window(for id: WindowID) -> SAGAWindow? {
            windows.withLock { $0[id] }
        }
    }
#endif
