//
//  SAGANativeRenderBackend.swift
//  AdaEngine
//
//  Native render backend on SAGA's Vulkan and Direct3D 12 runtimes.
//

#if SAGA_RENDER && SAGA_NATIVE && (os(Windows) || os(Linux) || os(Android)) && canImport(SAGAVulkan) && canImport(SAGACompiler)
    import AdaUtils
    import Foundation
    import Logging
    import Math
    import SAGA
    import SAGACore
    #if SAGA_D3D12
        import SAGAD3D12
    #endif
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
            case unknownWindowsRenderer(String)
            case direct3D12Unavailable

            var errorDescription: String? {
                switch self {
                case .noAdapter: "No Vulkan adapter is available for the SAGA renderer."
                case .unsupportedWindow: "The SAGA renderer received an unsupported native window surface."
                case .windowlessDevice: "The SAGA device was created for offscreen rendering."
                case .windowAlreadyRegistered: "A SAGA surface is already registered for this window."
                case .unknownWindowsRenderer(let value): "Unknown value '\(value)' for ADAENGINE_WINDOWS_RENDERER. Use vulkan or direct3d12."
                case .direct3D12Unavailable: "This build does not include SAGA Direct3D 12."
                }
            }
        }

        enum WindowsRenderer: String {
            case vulkan
            case direct3D12 = "direct3d12"

            static func configured() throws -> Self {
                guard let requested = ProcessInfo.processInfo.environment["ADAENGINE_WINDOWS_RENDERER"], !requested.isEmpty else {
                    return .vulkan
                }
                guard let renderer = Self(rawValue: requested.lowercased()) else {
                    throw SetupError.unknownWindowsRenderer(requested)
                }
                return renderer
            }
        }

        private enum NativeDevice: Sendable {
            case vulkan(VulkanDevice)
            #if SAGA_D3D12
            case direct3D12(D3D12Device)
            #endif

            func attachSurface(
                _ target: VulkanSurfaceTarget,
                presentation: RenderPresentationMode,
                onPresentationRetryChanged: @escaping @Sendable (Bool) -> Void
            ) async throws -> (id: UInt32, mode: RenderPresentationMode) {
                switch self {
                case .vulkan(let device):
                    if presentation == .uncapped {
                        let surface = try await device.attachUncappedSurface(target, onPresentationRetryChanged: onPresentationRetryChanged)
                        return (surface.id, surface.usesImmediate ? .uncapped : .synchronized)
                    }
                    let surface = try await device.attachSurface(
                        target,
                        prefersLatestFrame: presentation == .synchronizedLatest,
                        onPresentationRetryChanged: onPresentationRetryChanged
                    )
                    return (surface.id, surface.usesMailbox ? .synchronizedLatest : .synchronized)
                #if SAGA_D3D12
                case .direct3D12(let device):
                    guard case .win32(_, let hwnd) = target else { throw SetupError.unsupportedWindow }
                    return (try await device.addSurface(windowHandle: hwnd), .synchronized)
                #endif
                }
            }

            func removeSurface(_ id: UInt32) async {
                switch self {
                case .vulkan(let device): await device.removeSurface(id)
                #if SAGA_D3D12
                case .direct3D12(let device): await device.removeSurface(id)
                #endif
                }
            }
        }

        let context: SAGAContext
        private let native: NativeDevice
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
        init(
            windowless: Bool = ProcessInfo.processInfo.environment["ADAENGINE_SAGA_WINDOWLESS"] == "1",
            windowsRenderer: WindowsRenderer = .vulkan
        ) throws {
            #if os(Windows)
                if windowsRenderer == .direct3D12 {
                    #if SAGA_D3D12
                    let backend = windowless ? try D3D12Backend.makeDevice() : try D3D12Backend.makePresentableDevice()
                    native = .direct3D12(backend)
                    context = SAGAContext(
                        capabilities: backend.capabilities,
                        supportsPresentation: backend.supportsPresentation,
                        shaderOutput: .hlsl,
                        supportsPackedVertexIndexBuffers: backend.supportsPackedVertexIndexBuffers,
                        makeDevice: { try await Device.make(backend: backend) }
                    )
                    device = SAGARenderDevice(context: context)
                    device.windows = self
                    context.logger.info("Windows renderer: SAGA Direct3D 12 (default hardware adapter)")
                    return
                    #else
                    throw SetupError.direct3D12Unavailable
                    #endif
                }
                // NGX needs extra Vulkan extensions, so DLSS is prepared before the instance and device are created.
                let dlss = SAGADLSSSession.prepare()
            #endif
            guard let adapter = VulkanBackend.requestAdapter() else { throw SetupError.noAdapter }
            let backend = windowless
                ? try VulkanBackend.makeDevice(adapter: adapter)
                : try VulkanBackend.makePresentableDevice(adapter: adapter)
            self.native = .vulkan(backend)
            self.context = SAGAContext(
                capabilities: backend.capabilities,
                supportsPresentation: backend.supportsPresentation,
                shaderOutput: .spirv,
                makeDevice: { try await Device.make(backend: backend) }
            )
            #if os(Windows)
                context.dlssSession.withLock { $0 = dlss }
                dlss.start(on: context)
                context.logger.info("Windows renderer: SAGA Vulkan (\(adapter.name))")
            #endif
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
            let waitsForPresentation: Bool
            let limitsQueuedPresentations: Bool
            #if os(Windows)
                guard let nativeSurface = surface as? WindowsSurface else { throw SetupError.unsupportedWindow }
                target = unsafe .win32(
                    hinstance: UInt(bitPattern: GetModuleHandleW(nil)),
                    hwnd: UInt(bitPattern: nativeSurface.windowHwnd)
                )
                lifetime = nil
                waitsForPresentation = false
                limitsQueuedPresentations = true
            #elseif os(Linux)
                guard let nativeSurface = surface as? LinuxXlibRenderSurface else { throw SetupError.unsupportedWindow }
                target = unsafe .xlib(display: UInt(bitPattern: nativeSurface.xlibDisplay), window: UInt(nativeSurface.xlibWindow))
                lifetime = nativeSurface.xlibWindowLifetime
                waitsForPresentation = false
                limitsQueuedPresentations = false
            #elseif os(Android)
                guard let nativeSurface = surface as? AndroidNativeWindowRenderSurface else { throw SetupError.unsupportedWindow }
                target = unsafe .android(window: UInt(bitPattern: nativeSurface.nativeWindow))
                lifetime = nativeSurface.nativeWindowLifetime
                waitsForPresentation = true
                limitsQueuedPresentations = false
            #endif
            let window = SAGAWindow(
                context: context,
                windowId: windowId,
                size: size,
                scaleFactor: surface.scaleFactor,
                pixelFormat: surface.prefferedPixelFormat,
                surfaceID: nil,
                waitsForPresentation: waitsForPresentation,
                limitsQueuedPresentations: limitsQueuedPresentations
            )
            let native = self.native
            #if os(Windows)
                let presentation = context.shaderOutput == .spirv ? (unsafe RenderEngine.presentationMode) : .synchronized
            #else
                let presentation = RenderPresentationMode.synchronized
            #endif
            let logger = context.logger
            let surfaceSlot = window.surface
            context.queue.enqueue { _ in
                defer { withExtendedLifetime(lifetime) {} }
                let surface = try await native.attachSurface(target, presentation: presentation) { [weak window] in
                    window?.updatePresentationRetry($0)
                }
                if presentation == .uncapped {
                    logger.info("Windows Vulkan presentation: \(surface.mode == .uncapped ? "immediate" : "FIFO (uncapped unavailable)")")
                } else if presentation == .synchronizedLatest {
                    logger.info("Windows Vulkan presentation: \(surface.mode == .synchronizedLatest ? "mailbox" : "FIFO")")
                }
                window.setPresentationMode(surface.mode)
                surfaceSlot.fulfill(surface.id)
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
            let native = self.native
            binding.window.retire { id in
                defer { withExtendedLifetime(binding.lifetime) {} }
                await native.removeSurface(id)
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
    /// Older SDKs attach FIFO surfaces with the original single-argument API.
    private protocol VulkanWindowSurfaceAPI: Actor {
        func addSurface(_ target: VulkanSurfaceTarget) throws -> UInt32
        func addSurface(_ target: VulkanSurfaceTarget, onPresentationRetryChanged: (@Sendable (Bool) -> Void)?) throws -> UInt32
    }

    extension VulkanDevice: VulkanWindowSurfaceAPI {}

    #if os(Windows) && SAGA_D3D12
        /// Older Direct3D 12 SDKs support indexed draws with separate vertex and index buffers.
        private protocol D3D12PackedGeometryAPI: Actor {
            nonisolated var supportsPackedVertexIndexBuffers: Bool { get }
        }

        extension D3D12Device: D3D12PackedGeometryAPI {}

        private extension D3D12PackedGeometryAPI {
            nonisolated var supportsPackedVertexIndexBuffers: Bool { false }
        }
    #endif

    private extension VulkanWindowSurfaceAPI {
        func addSurface(_ target: VulkanSurfaceTarget, onPresentationRetryChanged: (@Sendable (Bool) -> Void)?) throws -> UInt32 {
            try addSurface(target)
        }

        func attachSurface(
            _ target: VulkanSurfaceTarget,
            prefersLatestFrame: Bool,
            onPresentationRetryChanged: (@Sendable (Bool) -> Void)?
        ) throws -> (id: UInt32, usesMailbox: Bool) {
            (try addSurface(target, onPresentationRetryChanged: onPresentationRetryChanged), false)
        }

        // The package's pinned SAGA remains usable until the immediate presentation API is available there.
        func attachUncappedSurface(
            _ target: VulkanSurfaceTarget, onPresentationRetryChanged: (@Sendable (Bool) -> Void)?
        ) throws -> (id: UInt32, usesImmediate: Bool) {
            let surface = try attachSurface(target, prefersLatestFrame: false, onPresentationRetryChanged: onPresentationRetryChanged)
            return (surface.id, false)
        }
    }
#endif
