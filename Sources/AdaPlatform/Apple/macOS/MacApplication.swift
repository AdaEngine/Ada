//
//  MacApplication.swift
//  AdaEngine
//
//  Created by v.prusakov on 10/9/21.
//

#if MACOS
    import AdaApp
    import AdaECS
    @_spi(Internal) import AdaInput
    @_spi(Internal) import AdaUI
    import AdaUtils
    import AppKit
    import MetalKit

    final class MacApplication: Application {
        private let lifecycleHandler = MacAppDelegate()
        private let screenManager: MacOSScreenManager

        override init(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws {
            unsafe Color.accentColor = NSColor.controlAccentColor.toColor
            self.screenManager = MacOSScreenManager()
            Screen.screenManager = screenManager
            unsafe try super.init(argc: argc, argv: argv)
            self.windowManager = MacOSWindowManager(screenManager)
            UIWindowManager.setShared(self.windowManager)

            // Create application
            let app = AdaApplication.shared
            app.setActivationPolicy(.regular)

            app.finishLaunching()
            app.delegate = self.lifecycleHandler

            self.processEvents()
            app.activate(ignoringOtherApps: true)
        }

        private var task: Task<Void, Never>?
        private var displayLink: DisplayLink?
        private var frameContinuation: AsyncStream<Void>.Continuation?
        private weak var linkedScreen: NSScreen?

        override func run(_ appWorlds: AppWorlds) throws {
            setupInput(for: appWorlds)
            if let screen = screenManager.activeScreen() {
                startDisplayLinkedLoop(for: appWorlds, screen: screen)
            } else {
                startFallbackLoop(for: appWorlds)
            }

            NSApplication.shared.run()
        }

        override func terminate() {
            frameContinuation?.finish()
            frameContinuation = nil
            displayLink?.invalidate()
            displayLink = nil
            linkedScreen = nil
            task?.cancel()
            NSApplication.shared.terminate(nil)
        }

        @discardableResult
        override func openURL(_ url: URL) -> Bool {
            NSWorkspace.shared.open(url)
        }

        override func showAlert(_ alert: Alert) {
            let nsAlert = NSAlert()
            nsAlert.alertStyle = .warning
            nsAlert.messageText = alert.title
            nsAlert.informativeText = alert.message ?? ""

            for button in alert.buttons {
                let nsButton = nsAlert.addButton(withTitle: button.title)

                // hack from that thread: https://stackoverflow.com/a/16627982
                if button.kind == .cancel {
                    nsButton.keyEquivalent = "\\r"
                }
            }

            let result = nsAlert.runModal()  // synchronous call

            // hack from that thread: https://stackoverflow.com/a/59245758
            let index = result.rawValue - 1000
            alert.buttons[index].action?()

            Application.shared.windowManager.activeWindow?.showWindow(makeFocused: true)
        }

        // MARK: - Private

        private func setupInput(for app: AppWorlds) {
            let mutableInput = app.main.getRefResource(Input.self)
            self.windowManager.inputRef = mutableInput
        }

        private func processEvents() {
            while let event = NSApp.nextEvent(
                matching: .any,
                until: .distantPast,
                inMode: .default,
                dequeue: true
            ) {
                NSApp.sendEvent(event)
            }
        }

        private func startDisplayLinkedLoop(for appWorlds: AppWorlds, screen: NSScreen) {
            let displayLink = DisplayLink(screen: screen)
            let (frames, continuation) = AsyncStream<Void>
                .makeStream(
                    bufferingPolicy: .bufferingNewest(1)
                )
            displayLink.setHandler {
                continuation.yield(())
            }
            self.displayLink = displayLink
            self.linkedScreen = screen
            self.frameContinuation = continuation
            configure(displayLink, for: appWorlds, screen: screen)

            task = Task(priority: .userInitiated) { [weak self] in
                do {
                    for await _ in frames {
                        try Task.checkCancellation()
                        guard let self else {
                            return
                        }
                        self.refreshDisplayLinkIfNeeded(
                            for: appWorlds,
                            continuation: continuation
                        )
                        try await MacApplicationFramePump.run(
                            processEvents: self.processEvents,
                            update: appWorlds.update
                        )
                        if let currentDisplayLink = self.displayLink,
                            let currentScreen = self.linkedScreen {
                            self.configure(currentDisplayLink, for: appWorlds, screen: currentScreen)
                        }
                    }
                } catch is CancellationError {
                } catch {
                    self?.showUpdateError(error)
                }
            }
            displayLink.start()
        }

        private func refreshDisplayLinkIfNeeded(
            for appWorlds: AppWorlds,
            continuation: AsyncStream<Void>.Continuation
        ) {
            guard let screen = screenManager.activeScreen(), screen !== linkedScreen else {
                return
            }

            let replacement = DisplayLink(screen: screen)
            replacement.setHandler {
                continuation.yield(())
            }
            configure(replacement, for: appWorlds, screen: screen)
            replacement.start()

            displayLink?.invalidate()
            displayLink = replacement
            linkedScreen = screen
        }

        private func startFallbackLoop(for appWorlds: AppWorlds) {
            task = Task(priority: .userInitiated) { [weak self] in
                do {
                    while true {
                        let frameStartedAt = Time.absolute
                        try Task.checkCancellation()
                        guard let self else {
                            return
                        }
                        try await MacApplicationFramePump.run(
                            processEvents: self.processEvents,
                            update: appWorlds.update
                        )
                        try await self.waitForNextFrameIfNeeded(startedAt: frameStartedAt, appWorlds: appWorlds)
                    }
                } catch is CancellationError {
                } catch {
                    self?.showUpdateError(error)
                }
            }
        }

        private func configure(_ displayLink: DisplayLink, for appWorlds: AppWorlds, screen: NSScreen) {
            guard let framePacing = appWorlds.getResource(ApplicationFramePacing.self) else {
                return
            }
            displayLink.setPreferredFrameRateRange(
                framePacing.resolvedFrameRateRange(
                    forDisplayMaximumFramesPerSecond: screen.maximumFramesPerSecond
                )
            )
        }

        private func waitForNextFrameIfNeeded(
            startedAt frameStartedAt: LongTimeInterval,
            appWorlds: AppWorlds
        ) async throws {
            guard let framePacing = appWorlds.getResource(ApplicationFramePacing.self) else {
                await Task.yield()
                return
            }

            let remainingTime = framePacing.minimumFrameDuration - (Time.absolute - frameStartedAt)
            guard remainingTime > 0 else {
                await Task.yield()
                return
            }

            try await Task.sleep(nanoseconds: UInt64(remainingTime * 1_000_000_000))
        }

        private func showUpdateError(_ error: any Error) {
            let alert = Alert(
                title: "AdaEngine finished with Error",
                message: error.localizedDescription,
                buttons: [
                    .cancel("OK", action: { exit(EXIT_FAILURE) })
                ]
            )
            Application.shared.showAlert(alert)
        }
    }

    @MainActor
    enum MacApplicationFramePump {
        static func run(
            processEvents: () -> Void,
            update: () async throws -> Void
        ) async rethrows {
            processEvents()
            try await update()
        }
    }

    class AdaApplication: NSApplication {
        override func sendEvent(_ event: NSEvent) {
            if event.type == .keyUp && event.modifierFlags.contains(.command) {
                self.keyWindow?.sendEvent(event)
            } else {
                super.sendEvent(event)
            }
        }
    }

    extension NSColor {
        var toColor: AdaUtils.Color {
            Color(
                red: Float(self.cgColor.components?[0] ?? 0),
                green: Float(self.cgColor.components?[1] ?? 0),
                blue: Float(self.cgColor.components?[2] ?? 0),
                alpha: Float(self.cgColor.alpha)
            )
        }
    }

#endif
