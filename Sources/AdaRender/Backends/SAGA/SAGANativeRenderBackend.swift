//
//  SAGANativeRenderBackend.swift
//  AdaEngine
//
//  Native render backend on SAGA's Vulkan runtime.
//

#if SAGA_RENDER && SAGA_NATIVE && (os(Windows) || os(Linux) || os(Android)) && canImport(SAGAVulkan) && canImport(SAGACompiler)
    import AdaUtils
    import Foundation
    import Math
    import SAGA
    import SAGACore
    import SAGAShaderIR
    import SAGATypes
    import SAGAVulkan
    import Synchronization
    #if os(Windows)
        import WinSDK
    #endif

    @_spi(Internal)
    public final class SAGANativeRenderBackend: RenderBackend, SAGAWindowProvider, @unchecked Sendable {
        enum SetupError: LocalizedError {
            case noAdapter
            case unsupportedWindow
            case windowlessDevice
            case windowAlreadyRegistered

            var errorDescription: String? {
                switch self {
                case .noAdapter: "No Vulkan adapter is available for the SAGA renderer."
                case .unsupportedWindow: "The SAGA renderer received an unsupported native window surface."
                case .windowlessDevice: "The SAGA device was created for offscreen rendering."
                case .windowAlreadyRegistered: "A SAGA surface is already registered for this window."
                }
            }
        }

        let context: SAGAContext
        private let vulkan: VulkanDevice
        private let device: SAGARenderDevice
        private struct WindowBinding: Sendable {
            let window: SAGAWindow
            let lifetime: (any Sendable)?
        }

        private let windows = Mutex<[WindowID: WindowBinding]>([:])

        var type: RenderBackendType { .saga }
        var renderDevice: RenderDevice { device }

        /// - Parameter windowless: Disable swapchain support for offscreen tests and tools.
        ///   Defaults to `ADAENGINE_SAGA_WINDOWLESS=1`.
        init(windowless: Bool = ProcessInfo.processInfo.environment["ADAENGINE_SAGA_WINDOWLESS"] == "1") throws {
            guard let adapter = VulkanBackend.requestAdapter() else { throw SetupError.noAdapter }
            let backend = windowless
                ? try VulkanBackend.makeDevice(adapter: adapter)
                : try VulkanBackend.makePresentableDevice(adapter: adapter)
            self.vulkan = backend
            self.context = SAGAContext(
                capabilities: backend.capabilities,
                supportsPresentation: backend.supportsPresentation,
                shaderOutput: .spirv,
                makeDevice: { try await Device.make(backend: backend) }
            )
            self.device = SAGARenderDevice(context: context)
            self.device.windows = self
        }

        func createLocalRenderDevice() -> RenderDevice {
            // Textures and samplers made through this device are used by the renderer's passes, so they must live on
            // the same SAGA device: a resource id is only valid on the device that created it.
            SAGARenderDevice(context: context)
        }

        @MainActor
        func createWindow(_ windowId: WindowID, for surface: RenderSurface, size: SizeInt) throws {
            guard context.supportsPresentation else { throw SetupError.windowlessDevice }
            guard window(for: windowId) == nil else { throw SetupError.windowAlreadyRegistered }
            let target: VulkanSurfaceTarget
            let lifetime: (any Sendable)?
            #if os(Windows)
                guard let nativeSurface = surface as? WindowsSurface else { throw SetupError.unsupportedWindow }
                target = unsafe .win32(
                    hinstance: UInt(bitPattern: GetModuleHandleW(nil)),
                    hwnd: UInt(bitPattern: nativeSurface.windowHwnd)
                )
                lifetime = nil
            #elseif os(Linux)
                guard let nativeSurface = surface as? LinuxXlibRenderSurface else { throw SetupError.unsupportedWindow }
                target = unsafe .xlib(display: UInt(bitPattern: nativeSurface.xlibDisplay), window: UInt(nativeSurface.xlibWindow))
                lifetime = nativeSurface.xlibWindowLifetime
            #elseif os(Android)
                guard let nativeSurface = surface as? AndroidNativeWindowRenderSurface else { throw SetupError.unsupportedWindow }
                target = unsafe .android(window: UInt(bitPattern: nativeSurface.nativeWindow))
                lifetime = nativeSurface.nativeWindowLifetime
            #endif
            let window = SAGAWindow(
                context: context,
                windowId: windowId,
                size: size,
                scaleFactor: surface.scaleFactor,
                pixelFormat: surface.prefferedPixelFormat,
                surfaceID: nil
            )
            let vulkan = self.vulkan
            let surfaceSlot = window.surface
            context.queue.enqueue { _ in
                defer { withExtendedLifetime(lifetime) {} }
                surfaceSlot.fulfill(try await vulkan.addSurface(target))
            }
            windows.withLock { $0[windowId] = WindowBinding(window: window, lifetime: lifetime) }
        }

        @MainActor
        func resizeWindow(_ windowId: WindowID, newSize: SizeInt) throws {
            window(for: windowId)?.resize(to: newSize)
        }

        @MainActor
        func resizeWindow(_ windowId: WindowID, newSize: SizeInt, scaleFactor: Float) throws {
            window(for: windowId)?.resize(to: newSize, scaleFactor: scaleFactor)
        }

        @MainActor
        func destroyWindow(_ windowId: WindowID) throws {
            guard let binding = windows.withLock({ $0.removeValue(forKey: windowId) }) else {
                return
            }
            let vulkan = self.vulkan
            binding.window.retire { id in
                defer { withExtendedLifetime(binding.lifetime) {} }
                await vulkan.removeSurface(id)
            }
        }

        @MainActor
        func getRenderWindow(for windowId: WindowID) -> RenderWindow? {
            window(for: windowId)?.renderWindow
        }

        @MainActor
        func getRenderWindows() throws -> RenderWindows {
            var set = SparseSet<WindowID, RenderWindow>()
            for (id, binding) in windows.withLock({ $0 }) {
                set.insert(binding.window.renderWindow, for: id)
            }
            return RenderWindows(windows: set)
        }

        func window(for id: WindowID) -> SAGAWindow? {
            windows.withLock { $0[id]?.window }
        }
    }
#endif
