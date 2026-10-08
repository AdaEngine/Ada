#if os(iOS)
    @_spi(AdaEngine) import AdaEngine

    @MainActor
    enum MobileEditorWindowLauncher {
        private static weak var window: UIWindow?

        static func open() {
            if let window, UIWindowManager.shared.windows[window.id] != nil {
                window.showWindow(makeFocused: true)
                return
            }
            let configuration = UIWindow.Configuration(
                title: "Ada Studio · Agent",
                frame: Rect(x: 0, y: 0, width: 680, height: 900),
                minimumSize: Size(width: 380, height: 600),
                mode: .windowed,
                titleBar: .init(background: .transparent, reservesSafeArea: true),
                showsImmediately: false,
                makeKey: true
            )
            let window = UIWindowManager.shared.spawnWindow(configuration: configuration) {
                MobileEditorRootView().theme(.adaEditor)
            }
            self.window = window
            window.showWindow(makeFocused: true)
        }
    }
#endif
