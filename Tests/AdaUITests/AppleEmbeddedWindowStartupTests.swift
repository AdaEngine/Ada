#if IOS || TVOS || VISIONOS
    @testable import AdaPlatform
    @_spi(Internal) import AdaUI
    import AdaUtils
    import Math
    import Testing

    @Suite("Apple embedded window startup")
    @MainActor
    struct AppleEmbeddedWindowStartupTests {
        @Test("Creating and showing a window waits for UIKit scene connection")
        func defersNativeWindowCreation() {
            let previousManager = UIWindowManager.shared ?? UIWindowManager()
            let manager = AppleEmbeddedWindowManager(screenManager: AppleEmbeddedScreenManager())
            UIWindowManager.setShared(manager)
            defer { UIWindowManager.setShared(previousManager) }

            let window = StartupWindow(frame: .zero)
            window.showWindow(makeFocused: true)

            #expect(!manager.isUIKitReady)
            #expect(window.systemWindow == nil)
            #expect(manager.windows[window.id] == nil)
            #expect(window.readyCount == 0)
        }

        @Test("A queued window can be closed without constructing UIKit or render resources")
        func closesBeforeSceneConnection() {
            let previousManager = UIWindowManager.shared ?? UIWindowManager()
            let manager = AppleEmbeddedWindowManager(screenManager: AppleEmbeddedScreenManager())
            UIWindowManager.setShared(manager)
            defer { UIWindowManager.setShared(previousManager) }

            let window = StartupWindow(frame: .zero)
            window.showWindow(makeFocused: true)
            var didDisappear = false
            window.onDidDisappear = { didDisappear = true }
            window.close()

            #expect(didDisappear)
            #expect(window.systemWindow == nil)
            #expect(manager.windows[window.id] == nil)
            #expect(window.readyCount == 0)
        }
    }

    @MainActor
    private final class StartupWindow: UIWindow {
        var readyCount = 0

        override func windowDidReady() {
            readyCount += 1
        }
    }
#endif
