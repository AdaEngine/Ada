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
    @_spi(Internal) import AdaUI
    import AdaUtils
    import Foundation
    import WinSDK

    final class WindowsApplication: Application {
        private var task: Task<Void, Never>?
        private let screenManager: WindowsScreenManager

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

        private static func enableDPIAwareness() {
            if SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) {
                return
            }

            SetProcessDPIAware()
        }
    }

#endif
