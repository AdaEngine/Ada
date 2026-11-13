// AdaRender's Apple window adapter for SAGA.

#if SAGA_METAL && canImport(SAGAMetal)
    import AdaUtils
    import Foundation
    import Math
    import MetalKit
    import QuartzCore
    import SAGACore
    import SAGAMetal
    import SAGAShaderIR
    import Synchronization

    final class SAGAMetalRenderBackend: RenderBackend, SAGAWindowProvider, Sendable {
        private enum SurfaceError: LocalizedError {
            case missingMetalLayer
            case windowAlreadyRegistered

            var errorDescription: String? {
                switch self {
                case .missingMetalLayer: "SAGA Metal requires a view with a CAMetalLayer."
                case .windowAlreadyRegistered: "A SAGA Metal surface is already registered for this window."
                }
            }
        }

        private struct WindowBinding: Sendable {
            let window: SAGAWindow
            let scaleFactor: @MainActor @Sendable () -> Float
        }

        let context: SAGAContext
        private let metal: MetalDevice
        private let device: SAGARenderDevice
        private let windows = Mutex<[WindowID: WindowBinding]>([:])

        let type: RenderBackendType = .saga
        var renderDevice: RenderDevice { device }

        init() throws {
            let metal = try MetalBackend.makePresentableDevice()
            self.metal = metal
            context = SAGAContext(
                capabilities: metal.capabilities,
                supportsPresentation: metal.supportsPresentation,
                shaderOutput: .msl,
                makeDevice: { try await Device.make(backend: metal) }
            )
            device = SAGARenderDevice(context: context)
            device.windows = self
        }

        func createLocalRenderDevice() -> RenderDevice {
            SAGARenderDevice(context: context)
        }

        @MainActor
        func createWindow(_ windowId: WindowID, for surface: RenderSurface, size: SizeInt) throws {
            try createWindow(windowId, for: surface, size: size, onPresented: nil)
        }

        @MainActor
        func createWindow(
            _ windowId: WindowID,
            for surface: RenderSurface,
            size: SizeInt,
            onPresented: (@MainActor @Sendable (MetalPresentedFrame) -> Void)?
        ) throws {
            guard window(for: windowId) == nil else {
                throw SurfaceError.windowAlreadyRegistered
            }
            guard let view = surface as? MTKView else {
                throw SurfaceError.missingMetalLayer
            }
            view.device = metal.metalDevice
            view.colorPixelFormat = .bgra8Unorm
            view.sampleCount = 1
            guard let layer = view.layer as? CAMetalLayer else {
                throw SurfaceError.missingMetalLayer
            }
            layer.frame = view.bounds
            layer.contentsScale = CGFloat(view.scaleFactor)
            layer.isOpaque = view.isOpaque
            let id = try metal.addSurface(MetalPresentationSurface(layer: layer, onPresented: onPresented))
            let window = SAGAWindow(
                context: context,
                windowId: windowId,
                size: size,
                scaleFactor: surface.scaleFactor,
                pixelFormat: surface.prefferedPixelFormat,
                surfaceID: id
            )
            windows.withLock {
                $0[windowId] = WindowBinding(window: window, scaleFactor: { [weak view] in view?.scaleFactor ?? 1 })
            }
        }

        @MainActor
        func resizeWindow(_ windowId: WindowID, newSize: SizeInt) throws {
            if let binding = windows.withLock({ $0[windowId] }) {
                binding.window.resize(to: newSize, scaleFactor: binding.scaleFactor())
            }
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
            let metal = self.metal
            binding.window.retire { id in
                await metal.removeSurface(id)
            }
        }

        @MainActor
        func getRenderWindow(for windowId: WindowID) -> RenderWindow? {
            window(for: windowId)?.renderWindow
        }

        @MainActor
        func getRenderWindows() throws -> RenderWindows {
            var result = SparseSet<WindowID, RenderWindow>()
            for (id, binding) in windows.withLock({ $0 }) {
                result.insert(binding.window.renderWindow, for: id)
            }
            return RenderWindows(windows: result)
        }

        func window(for id: WindowID) -> SAGAWindow? {
            windows.withLock { $0[id]?.window }
        }
    }
#endif
