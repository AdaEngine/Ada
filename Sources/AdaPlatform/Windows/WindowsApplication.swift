//
//  WindowsApplication.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/9/23.
//

#if os(Windows)
    import AdaApp
    import AdaECS
    @_spi(Internal) import AdaInput
    import AdaRender
    @_spi(Internal) import AdaUI
    import AdaUtils
    import Foundation
    import WinSDK

    final class WindowsApplication: Application {
        private var task: Task<Void, Never>?
        private let screenManager: WindowsScreenManager
        private var backgroundFrameDeadline: LongTimeInterval?
        /// Upper target for a foreground mailbox producer. Input can wake the pacing timer early.
        private static let mailboxFrameDuration: LongTimeInterval = 1.0 / 120.0
        /// `TIMER_ALL_ACCESS`; the macro is not imported into Swift.
        private static let timerAllAccess = DWORD(0x1F0003)
        /// High-resolution timer for frame pacing; `Task.sleep` follows the ~15.6 ms system tick and can stall longer.
        /// The application lives for the whole process, so the handle is released by the OS at exit.
        private lazy var frameTimer: HANDLE? = unsafe CreateWaitableTimerExW(
            nil, nil, DWORD(CREATE_WAITABLE_TIMER_HIGH_RESOLUTION), Self.timerAllAccess
        )

        override init(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws {
            Self.enableDPIAwareness()
            self.screenManager = WindowsScreenManager()
            unsafe WindowsScreenManager.shared = screenManager
            Screen.screenManager = screenManager
            unsafe try super.init(argc: argc, argv: argv)
            self.windowManager = WindowsWindowManager(screenManager)
            UIWindowManager.setShared(self.windowManager)
        }

        @MainActor
        override func run(_ appWorlds: AppWorlds) async throws {
            setupInput(for: appWorlds)
            do {
                var msg = unsafe MSG()
                while true {
                    let frameStartedAt = Time.absolute
                    try Task.checkCancellation()

                    // Process Windows messages
                    var hasMessage: Bool = false
                    hasMessage = unsafe PeekMessageW(&msg, nil, 0, 0, UInt32(1))
                    while hasMessage {
                        if msg.message == UInt32(WM_QUIT) {
                            return
                        }
                        unsafe TranslateMessage(&msg)
                        unsafe DispatchMessageW(&msg)
                        hasMessage = unsafe PeekMessageW(&msg, nil, 0, 0, UInt32(1))
                    }

                    try await appWorlds.update()
                    if let engine = unsafe RenderEngine.shared {
                        (windowManager as? WindowsWindowManager)?.retrySkippedPresentations(using: engine)
                    }
                    try await waitForNextFrameIfNeeded(startedAt: frameStartedAt, appWorlds: appWorlds)
                }
            } catch {
                let alert = Alert(
                    title: "AdaEngine finished with Error",
                    message: error.localizedDescription,
                    buttons: [
                        .cancel("OK", action: { exit(0) })
                    ]
                )
                Application.shared.showAlert(alert)
            }
        }

        override func terminate() {
            self.task?.cancel()
            PostQuitMessage(0)
        }

        @discardableResult
        override func openURL(_ url: URL) -> Bool {
            let urlString = url.absoluteString
            let result = unsafe ShellExecuteW(
                nil,
                "open".wide,
                urlString.wide,
                nil,
                nil,
                SW_SHOWNORMAL
            )
            return Int(bitPattern: result) > 32
        }

        override func showAlert(_ alert: Alert) {
            let message = alert.message ?? ""
            let title = alert.title

            let messageWide = message.wide
            let titleWide = title.wide

            unsafe MessageBoxW(nil, messageWide, titleWide, UINT(MB_OK | MB_ICONINFORMATION))

            // Execute first button action if available
            alert.buttons.first?.action?()

            Application.shared.windowManager.activeWindow?.showWindow(makeFocused: true)
        }

        // MARK: - Private

        private func setupInput(for app: AppWorlds) {
            let mutableInput = app.main.getRefResource(Input.self)
            self.windowManager.inputRef = mutableInput
        }

        private func waitForNextFrameIfNeeded(startedAt frameStartedAt: LongTimeInterval, appWorlds: AppWorlds) async throws {
            guard let framePacing = appWorlds.getResource(ApplicationFramePacing.self) else {
                backgroundFrameDeadline = nil
                await Task.yield()
                return
            }

            let frameRequests = appWorlds.getResource(WindowFrameRequests.self)
            let windows = windowManager as? WindowsWindowManager
            let foregroundWindow = windows?.foregroundRenderWindow(requests: nil)
            if foregroundWindow != nil { backgroundFrameDeadline = nil }
            var paceLatestFrameProducer = false
            if framePacing.synchronizesWithDisplayRefreshRate, let windows, let engine = unsafe RenderEngine.shared {
                // Only the foreground swapchain paces interactive input.
                if let id = foregroundWindow, frameRequests?.shouldRender(id) != false,
                    let mode = await engine.pacePendingWindowPresentation(id) {
                    if mode == .uncapped {
                        // A fast swapchain can leave no pending ticket to await. Let scene completions run on the main actor.
                        await Task.yield()
                        return
                    }
                    guard mode == .synchronizedLatest else {
                        return
                    }
                    // Mailbox can replace a queued frame immediately. Bound the producer in inexpensive scenes.
                    paceLatestFrameProducer = true
                }
                if engine.type == .webgpu, windows.hasVisibleRenderWindow(requests: frameRequests) {
                    await Task.yield()
                    return
                }
            }

            // A visible display-synchronized window that skipped this frame (an on-demand window waiting for
            // content) keeps the display's idle cadence. The 60 FPS fallback would add a 16.7 ms gap per skip.
            // Hidden or minimized windows keep the configured fallback limit.
            let windowVisible = windows?.hasVisibleRenderWindow(requests: nil) == true
            let frameDuration: LongTimeInterval
            if paceLatestFrameProducer {
                frameDuration = Self.mailboxFrameDuration
            } else if framePacing.synchronizesWithDisplayRefreshRate, windowVisible, let refreshRate = displayRefreshRate() {
                let range = framePacing.resolvedFrameRateRange(forDisplayMaximumFramesPerSecond: refreshRate, isIdle: true)
                frameDuration = 1 / LongTimeInterval(max(1, range.upperBound))
            } else {
                frameDuration = framePacing.minimumFrameDuration
            }
            let frameDeadline: LongTimeInterval
            if windowVisible, foregroundWindow == nil, framePacing.synchronizesWithDisplayRefreshRate,
                framePacing.idleMaximumFramesPerSecond != nil {
                // Keep the same phase across ticks so a timer wake-up a little past its deadline does not lower the frame rate.
                // A message can wake the timer early. Do not let those wakeups queue future intervals.
                let frameStart = min(backgroundFrameDeadline ?? frameStartedAt, frameStartedAt)
                let nextDeadline = frameStart + frameDuration
                frameDeadline = nextDeadline > frameStartedAt ? nextDeadline : frameStartedAt + frameDuration
                backgroundFrameDeadline = frameDeadline
            } else {
                backgroundFrameDeadline = nil
                frameDeadline = frameStartedAt + frameDuration
            }
            let remainingTime = frameDeadline - Time.absolute
            guard remainingTime > 0 else {
                await Task.yield()
                return
            }

            try Task.checkCancellation()
            // Run queued main-actor work first; the precise wait below blocks the main thread for at most one frame.
            await Task.yield()
            let waitTime = frameDeadline - Time.absolute
            if waitTime > 0 { waitPrecisely(seconds: waitTime) }
            // Let queued main-actor work, such as render-completion delivery, run before the next frame.
            await Task.yield()
        }

        private var cachedRefreshRate: (value: Int?, checkedAt: LongTimeInterval)?

        /// The primary display's current refresh rate, re-read at most once per second; nil when unknown.
        private func displayRefreshRate() -> Int? {
            let now = Time.absolute
            if let cachedRefreshRate, now - cachedRefreshRate.checkedAt < 1 {
                return cachedRefreshRate.value
            }
            var mode = DEVMODEW()
            mode.dmSize = WORD(MemoryLayout<DEVMODEW>.size)
            let frequency = unsafe EnumDisplaySettingsW(nil, DWORD.max /* ENUM_CURRENT_SETTINGS */, &mode) ? Int(mode.dmDisplayFrequency) : 0
            // 0 and 1 mean "hardware default"; the caller keeps the configured fallback then.
            let value: Int? = frequency > 1 ? frequency : nil
            cachedRefreshRate = (value, now)
            return value
        }

        /// Waits up to `seconds`, returning early when window input arrives.
        private func waitPrecisely(seconds: LongTimeInterval) {
            guard let timer = frameTimer else {
                Sleep(DWORD(max(1, (seconds * 1000).rounded(.up))))
                return
            }
            var due = LARGE_INTEGER()
            due.QuadPart = -LONGLONG((seconds * 10_000_000).rounded(.up))
            guard unsafe SetWaitableTimer(timer, &due, 0, nil, nil, false) else {
                Sleep(DWORD(max(1, (seconds * 1000).rounded(.up))))
                return
            }
            var handles: [HANDLE?] = [timer]
            _ = unsafe MsgWaitForMultipleObjectsEx(1, &handles, INFINITE, DWORD(QS_ALLINPUT), DWORD(MWMO_INPUTAVAILABLE))
        }

        private static func enableDPIAwareness() {
            if SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) {
                return
            }

            SetProcessDPIAware()
        }
    }

    extension WindowsWindowManager {
        func foregroundRenderWindow(requests: WindowFrameRequests?) -> WindowID? {
            guard let window = activeWindow,
                let systemWindow = window.systemWindow as? WindowsSystemWindow,
                unsafe systemWindow.hwnd == GetForegroundWindow(),
                isVisibleRenderWindow(window, requests: requests)
            else {
                return nil
            }
            return window.id
        }

        func retrySkippedPresentations(using engine: RenderEngine) {
            for window in windows where isVisibleRenderWindow(window, requests: nil) {
                engine.retryWindowPresentationIfNeeded(window.id)
            }
        }

        private func isVisibleRenderWindow(_ window: UIWindow, requests: WindowFrameRequests?) -> Bool {
            // Unknown windows retain continuous rendering, including embedded game runtimes with their own cameras.
            guard requests?.shouldRender(window.id) != false else {
                return false
            }
            guard window.canDraw, !window.isHidden, let systemWindow = window.systemWindow as? WindowsSystemWindow else {
                return false
            }
            return unsafe IsWindowVisible(systemWindow.hwnd) && !IsIconic(systemWindow.hwnd)
        }
    }

#endif
