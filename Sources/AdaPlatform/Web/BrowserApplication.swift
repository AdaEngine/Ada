//
//  BrowserApplication.swift
//  AdaEngine
//

#if WASM && canImport(JavaScriptKit)
    import AdaApp
    import AdaECS
    @_spi(Internal) import AdaInput
    @_spi(Internal) import AdaUI
    import AdaUtils
    import Foundation
    import JavaScriptEventLoop
    import JavaScriptKit
    import Logging

    @MainActor
    final class BrowserApplication: Application {
        private let screenManager: BrowserScreenManager
        private var frameLoop: BrowserFrameLoop?

        override init(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws {
            JavaScriptEventLoop.installGlobalExecutor()

            self.screenManager = BrowserScreenManager()
            Screen.screenManager = screenManager
            try super.init(argc: argc, argv: argv)
            self.windowManager = BrowserWindowManager(screenManager: screenManager)
            UIWindowManager.setShared(self.windowManager)
        }

        override func run(_ appWorlds: AppWorlds) async throws {
            setupInput(for: appWorlds)
            let frameLoop = BrowserFrameLoop(appWorlds: appWorlds)
            self.frameLoop = frameLoop
            frameLoop.start()

            try await withCheckedThrowingContinuation { (_ continuation: CheckedContinuation<Void, Error>) in
                frameLoop.onFatalError = { error in
                    continuation.resume(throwing: error)
                }
            }
        }

        override func terminate() {
            frameLoop?.stop()
        }

        @discardableResult
        override func openURL(_ url: URL) -> Bool {
            _ = JSObject.global.window.open(url.absoluteString)
            return true
        }

        override func showAlert(_ alert: Alert) {
            let message = [alert.title, alert.message].compactMap { $0 }.joined(separator: "\n\n")
            _ = JSObject.global.window.alert(message)
            alert.buttons.first?.action?()
        }

        private func setupInput(for app: AppWorlds) {
            let mutableInput = app.main.getRefResource(Input.self)
            self.windowManager.inputRef = mutableInput
        }
    }

    @MainActor
    private final class BrowserFrameLoop {
        var onFatalError: ((Error) -> Void)?

        private let appWorlds: AppWorlds
        private let logger = Logger(label: "org.adaengine.browser")
        private var isRunning = false
        private var isFrameUpdateInFlight = false
        private var animationFrameClosure: JSClosure?

        init(appWorlds: AppWorlds) {
            self.appWorlds = appWorlds
        }

        func start() {
            guard !isRunning else {
                return
            }

            isRunning = true
            scheduleNextFrame()
        }

        func stop() {
            isRunning = false
            animationFrameClosure = nil
        }

        private func scheduleNextFrame() {
            guard isRunning else {
                return
            }

            let closure = JSClosure { [weak self] _ in
                guard let self else {
                    return .undefined
                }

                MainActor.assumeIsolated {
                    self.animationFrameDidFire()
                }

                return .undefined
            }

            animationFrameClosure = closure
            _ = JSObject.global.window.requestAnimationFrame(closure)
        }

        private func animationFrameDidFire() {
            guard isRunning else {
                return
            }

            scheduleNextFrame()

            guard !isFrameUpdateInFlight else {
                return
            }

            isFrameUpdateInFlight = true
            Task { @MainActor in
                await self.tick()
            }
        }

        private func tick() async {
            guard isRunning else {
                isFrameUpdateInFlight = false
                return
            }

            defer {
                isFrameUpdateInFlight = false
            }

            do {
                try await appWorlds.update()
            } catch {
                logger.error("Browser frame failed: \(error)")
                isRunning = false
                onFatalError?(error)
            }
        }
    }
#endif
