#if os(iOS)
    @_spi(AdaEngine) import AdaEngine

    struct AdaEditorPhoneApp: App {
        var body: some AppScene {
            WindowGroup {
                MobileEditorRootView()
                    .theme(.adaEditor)
            }
            .windowMode(.windowed)
            .windowTitle("Ada Studio")
        }
    }
#endif
