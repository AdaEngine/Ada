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
        private let waitsForPresentation: Bool
        private let limitsQueuedPresentations: Bool
        private static let presentationLimit = 2
        /// The presentation surface of this window. Windows beyond the first receive theirs from the backend.
        let surface = ResourceSlot<UInt32>()
        private struct State {
            var size: SizeInt
            var scaleFactor: Float
            var backbuffer: SAGAGPUTexture?
            var lastPresentation: SubmissionTicket?
            var queuedPresentations = 0
            var presentationNeedsRetry = false
            var presentationWaiters: [AsyncStream<Bool>.Continuation] = []
            var usesMailbox = false
            var isPresenting = false
            var isRetired = false
        }

        private let state: Mutex<State>

        init(
            context: SAGAContext,
            windowId: WindowID,
            size: SizeInt,
            scaleFactor: Float,
            pixelFormat: PixelFormat,
            surfaceID: UInt32? = 0,
            waitsForPresentation: Bool = false,
            limitsQueuedPresentations: Bool = false
        ) {
            self.context = context
            self.windowId = windowId
            self.pixelFormat = pixelFormat
            self.waitsForPresentation = waitsForPresentation
            self.limitsQueuedPresentations = limitsQueuedPresentations
            if let surfaceID { surface.fulfill(surfaceID) }
            self.state = Mutex(State(size: size, scaleFactor: scaleFactor, backbuffer: nil))
        }

        func setMailboxPresentation(_ active: Bool) {
            state.withLock { $0.usesMailbox = active }
        }

        var presentationMode: RenderPresentationMode {
            state.withLock { $0.usesMailbox ? .synchronizedLatest : .synchronized }
        }

        var hasPendingPresentation: Bool {
            state.withLock { $0.queuedPresentations > 0 }
        }

        /// The visible swapchain paces the loop. Keep enough work queued for the GPU to overlap one update.
        func pacePendingPresentation() async -> Bool {
            guard limitsQueuedPresentations else {
                return false
            }
            let (stream, pending) = state.withLock { state -> (AsyncStream<Bool>?, Bool) in
                guard !state.isRetired, state.queuedPresentations > 0 else {
                    return (nil, false)
                }
                guard state.queuedPresentations >= Self.presentationLimit else {
                    return (nil, true)
                }
                let (stream, waiter) = AsyncStream<Bool>.makeStream()
                state.presentationWaiters.append(waiter)
                return (stream, true)
            }
            guard let stream else {
                return pending
            }
            var iterator = stream.makeAsyncIterator()
            return await iterator.next() ?? false
        }

        func updatePresentationRetry(_ needed: Bool) {
            guard limitsQueuedPresentations else {
                return
            }
            state.withLock { $0.presentationNeedsRetry = needed && !$0.isRetired }
        }

        /// Display the latest submitted texture again without running another render graph.
        func retryPresentationIfNeeded() {
            let backbuffer = state.withLock { state in
                state.presentationNeedsRetry && state.queuedPresentations == 0 ? state.backbuffer : nil
            }
            if let backbuffer { present(backbuffer) }
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
                guard !state.isRetired, !state.isPresenting, state.queuedPresentations < Self.presentationLimit else {
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
                guard !state.isRetired, !state.isPresenting, state.queuedPresentations < Self.presentationLimit else {
                    return
                }
                // Android can deliver Choreographer ticks faster than Vulkan can present.
                // Keep retirement from having to drain a backlog of frames for the old window.
                state.isPresenting = waitsForPresentation
                state.presentationNeedsRetry = false
                if limitsQueuedPresentations { state.queuedPresentations += 1 }
                context.queue.enqueue(onUnavailable: { [self] in finishPresentation() }) { [self] device in
                    var waitsOffQueue = false
                    defer { if !waitsOffQueue { finishPresentation() } }
                    let ticket = try await device.present(try backbuffer.slot.get(), surface: try surface.get())
                    self.state.withLock { $0.lastPresentation = ticket }
                    if limitsQueuedPresentations {
                        waitsOffQueue = true
                        context.queue.enqueueRetirement(ordered: false) { [self] in
                            defer { finishPresentation() }
                            try await ticket.wait()
                        }
                    } else if waitsForPresentation {
                        try await ticket.wait()
                    }
                }
            }
        }

        private func finishPresentation() {
            guard waitsForPresentation || limitsQueuedPresentations else {
                return
            }
            let waiters = state.withLock { state -> [AsyncStream<Bool>.Continuation] in
                state.isPresenting = false
                guard limitsQueuedPresentations else {
                    return []
                }
                state.queuedPresentations -= 1
                guard state.queuedPresentations < Self.presentationLimit else {
                    return []
                }
                defer { state.presentationWaiters.removeAll(keepingCapacity: true) }
                return state.presentationWaiters
            }
            for waiter in waiters {
                waiter.yield(true)
                waiter.finish()
            }
        }

        func retire(_ removeSurface: @escaping @Sendable (UInt32) async -> Void) {
            let waiters = state.withLock { state -> [AsyncStream<Bool>.Continuation] in
                guard !state.isRetired else {
                    return []
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
                defer { state.presentationWaiters.removeAll(keepingCapacity: true) }
                return state.presentationWaiters
            }
            for waiter in waiters { waiter.finish() }
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

        #if os(macOS) && SAGA_METAL
            func waitForPresentation() async {
                await withCheckedContinuation { continuation in
                    window.context.queue.enqueueCleanup {
                        continuation.resume()
                    }
                }
            }
        #endif
    }
#endif
