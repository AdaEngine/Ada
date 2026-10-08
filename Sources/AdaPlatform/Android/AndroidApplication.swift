#if os(Android)
    import AdaApp
    import AdaECS
    @_spi(Internal) import AdaInput
    @_spi(Internal) import AdaUI
    import AdaUtils
    import CAndroid
    import Foundation
    import Math
    import Synchronization

    @MainActor
    final class AndroidApplication: Application {
        private let screenManager: AndroidScreenManager
        private let frames: AsyncStream<Int64>
        private let frameContinuation: AsyncStream<Int64>.Continuation
        private var resumed = true
        private var updatingWorld = false
        private var pendingSurfaceLoss = false
        private var pendingResize: (Int32, Int32, Float)?
        private var reportsNextFrame = true
        private var contacts: [Int32: RID] = [:]

        override init(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws {
            screenManager = AndroidScreenManager()
            (frames, frameContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
            unsafe try super.init(argc: argc, argv: argv)
            Screen.screenManager = screenManager
            windowManager = AndroidWindowManager()
            UIWindowManager.setShared(windowManager)
        }

        override func run(_ appWorlds: AppWorlds) async throws {
            AndroidRuntime.log("Android frame loop started")
            windowManager.inputRef = appWorlds.main.getRefResource(Input.self)
            for await _ in frames {
                try Task.checkCancellation()
                guard resumed, unsafe ada_android_has_surface() else { continue }
                if reportsNextFrame { AndroidRuntime.log("Android active frame"); reportsNextFrame = false }
                updatingWorld = true
                defer {
                    updatingWorld = false
                    applySurfaceChanges()
                }
                try await appWorlds.update()
            }
        }

        func frame(_ time: Int64) { frameContinuation.yield(time) }
        func stop() { frameContinuation.finish() }

        func setResumed(_ value: Bool) {
            resumed = value
            if value { reportsNextFrame = true }
            if !value {
                for id in Array(contacts.keys) { touch(id: id, phase: 3, x: 0, y: 0) }
                if let window = windowManager.activeWindow { windowManager.resignActiveWindow(window) }
            } else if let window = windowManager.windows.values.first?.value {
                windowManager.setActiveWindow(window)
            }
        }

        func detachSurface() {
            pendingSurfaceLoss = true
            applySurfaceChanges()
        }

        func resize(width: Int32, height: Int32, scale: Float) {
            pendingResize = (width, height, scale)
            applySurfaceChanges()
        }

        // Reconfiguration invalidates acquired drawables. Wait until the complete
        // render graph has submitted/presented before changing the swapchain.
        private func applySurfaceChanges() {
            guard !updatingWorld else { return }
            if pendingSurfaceLoss {
                (windowManager as? AndroidWindowManager)?.surfaceLost()
                pendingSurfaceLoss = false
            }
            if let (width, height, scale) = pendingResize {
                pendingResize = nil
                screenManager.update(width: width, height: height, scale: scale)
                (windowManager as? AndroidWindowManager)?.surfaceChanged()
            }
        }

        func touch(id: Int32, phase: Int32, x: Float, y: Float) {
            guard let window = windowManager.windows.values.first?.value,
                let input = windowManager.inputRef
            else { return }
            let contact = contacts[id] ?? RID()
            contacts[id] = contact
            let touchPhase: TouchEvent.Phase
            switch phase {
            case 0: touchPhase = .began
            case 2: touchPhase = .ended
            case 3: touchPhase = .cancelled
            default: touchPhase = .moved
            }
            input.wrappedValue.receiveEvent(
                TouchEvent(
                    window: window.id,
                    location: Point(x: x / screenManager.metrics.scale, y: y / screenManager.metrics.scale),
                    phase: touchPhase,
                    time: Float(Time.absolute),
                    contactID: contact
                ))
            if phase >= 2 { contacts[id] = nil }
        }

        override func terminate() {
            setResumed(false)
            unsafe ada_android_finish()
        }

        override func openURL(_ url: URL) -> Bool {
            unsafe url.absoluteString.withCString { unsafe ada_android_open_url($0) }
        }
    }

    private final class AndroidScreen: SystemScreen, Sendable {}

    // Screen getters can be queried by render workers. Metrics are synchronized,
    // while the native screen identity is immutable for the activity lifetime.
    final class AndroidScreenManager: ScreenManager, Sendable {
        struct Metrics: Sendable {
            var size: Size
            var scale: Float
        }
        private let storage: Mutex<Metrics>
        private let systemScreen = AndroidScreen()
        var metrics: Metrics { storage.withLock { $0 } }

        init() {
            let scale = max(unsafe ada_android_scale(), 1)
            storage = Mutex(
                Metrics(
                    size: Size(width: Float(unsafe ada_android_width()) / scale, height: Float(unsafe ada_android_height()) / scale),
                    scale: scale
                ))
        }
        func update(width: Int32, height: Int32, scale: Float) {
            storage.withLock { $0 = Metrics(size: Size(width: Float(width) / scale, height: Float(height) / scale), scale: scale) }
        }
        func getMainScreen() -> Screen? { makeScreen(from: systemScreen) }
        func getScreens() -> [Screen] { [makeScreen(from: systemScreen)] }
        func getScreenScale(for _: Screen) -> Float { metrics.scale }
        func getSize(for _: Screen) -> Size { metrics.size }
        func getBrightness(for _: Screen) -> Float { 1 }
        func makeScreen(from systemScreen: SystemScreen) -> Screen { Screen(systemScreen: systemScreen, screenManager: self) }
    }
#endif
