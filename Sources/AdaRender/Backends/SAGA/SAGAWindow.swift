//
//  SAGAWindow.swift
//  AdaEngine
//

#if SAGA_RENDER && canImport(SAGACompiler)
    import Math
    import SAGA
    import SAGACore
    import SAGATypes
    import Synchronization

    /// Hands out the windows of a SAGA render backend to its device.
    protocol SAGAWindowProvider: AnyObject {
        func window(for id: WindowID) -> SAGAWindow?
    }

    /// A window is an offscreen color texture that is copied to the canvas on `present`.
    final class SAGAWindow: @unchecked Sendable {
        let context: SAGAContext
        let windowId: WindowID
        let pixelFormat: PixelFormat
        /// The presentation surface of this window. Windows beyond the first receive theirs from the backend.
        let surface = ResourceSlot<UInt32>()
        private struct State {
            var size: SizeInt
            var scaleFactor: Float
            var backbuffer: SAGAGPUTexture?
            var lastPresentation: SubmissionTicket?
            var isRetired = false
        }

        private let state: Mutex<State>

        init(context: SAGAContext, windowId: WindowID, size: SizeInt, scaleFactor: Float, pixelFormat: PixelFormat, surfaceID: UInt32? = 0) {
            self.context = context
            self.windowId = windowId
            self.pixelFormat = pixelFormat
            if let surfaceID { surface.fulfill(surfaceID) }
            self.state = Mutex(State(size: size, scaleFactor: scaleFactor, backbuffer: nil))
        }

        var renderWindow: RenderWindow {
            state.withLock {
                RenderWindow(windowId: windowId, height: $0.size.height, width: $0.size.width, scaleFactor: $0.scaleFactor)
            }
        }

        func resize(to size: SizeInt, scaleFactor: Float? = nil) {
            state.withLock {
                $0.size = size
                if let scaleFactor { $0.scaleFactor = scaleFactor }
                $0.backbuffer = nil
            }
        }

        /// Returns the texture for the current frame, creating it after a resize.
        func currentBackbuffer() -> SAGAGPUTexture? {
            state.withLock { state in
                guard !state.isRetired else {
                    return nil
                }
                if let backbuffer = state.backbuffer {
                    return backbuffer
                }
                let width = max(1, Int(Float(state.size.width) * state.scaleFactor))
                let height = max(1, Int(Float(state.size.height) * state.scaleFactor))
                let descriptor = TextureDescriptor(
                    width: width,
                    height: height,
                    pixelFormat: pixelFormat,
                    textureUsage: [.renderTarget, .read],
                    textureType: .texture2D,
                    debugLabel: "Window backbuffer"
                )
                state.backbuffer = try? SAGAGPUTexture(context: context, descriptor: descriptor)
                return state.backbuffer
            }
        }

        func present(_ backbuffer: SAGAGPUTexture) {
            state.withLock { state in
                guard !state.isRetired else {
                    return
                }
                context.queue.enqueue { [self] device in
                    let ticket = try await device.present(try backbuffer.slot.get(), surface: try surface.get())
                    self.state.withLock { $0.lastPresentation = ticket }
                }
            }
        }

        func retire(_ removeSurface: @escaping @Sendable (UInt32) async -> Void) {
            state.withLock { state in
                guard !state.isRetired else {
                    return
                }
                state.isRetired = true
                context.queue.enqueueCleanup { [self] in
                    guard let id = try? surface.get() else {
                        return
                    }
                    let ticket = self.state.withLock { $0.lastPresentation }
                    do {
                        try await ticket?.wait()
                    } catch {
                        await removeSurface(id)
                        throw error
                    }
                    await removeSurface(id)
                }
            }
        }
    }

    final class SAGASwapchain: Swapchain, @unchecked Sendable {
        let window: SAGAWindow

        init(window: SAGAWindow) {
            self.window = window
        }

        var drawablePixelFormat: PixelFormat { window.pixelFormat }

        func getNextDrawable(_: RenderDevice) -> (any Drawable)? {
            guard let texture = window.currentBackbuffer() else {
                return nil
            }
            return SAGADrawable(texture: texture, window: window)
        }
    }

    final class SAGADrawable: Drawable, @unchecked Sendable {
        let texture: any GPUTexture
        private let backbuffer: SAGAGPUTexture
        private let window: SAGAWindow

        init(texture: SAGAGPUTexture, window: SAGAWindow) {
            self.texture = texture
            self.backbuffer = texture
            self.window = window
        }

        func present() throws {
            window.present(backbuffer)
        }
    }
#endif
