//
//  AppleWindowManager.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/9/23.
//

#if canImport(MetalKit)
    @_spi(Internal) import AdaEngine
    @_spi(Internal) import AdaPlatform
    #if canImport(AppKit)
        import AppKit
    #elseif canImport(UIKit)
        import UIKit
    #endif
    import MetalKit

    /// Because we don't have windows, this object is blank and using only for avoid crashes when windows will change their states.
    final class AppleWindowManager: UIWindowManager {
        weak var nativeView: MetalView?
        var screenManager: ScreenManager

        init(screenManager: ScreenManager) {
            self.screenManager = screenManager
        }

        override func resizeWindow(_: AdaEngine.UIWindow, size _: Size) {
        }

        override func setWindowMode(_: AdaEngine.UIWindow, mode _: AdaEngine.UIWindow.Mode) {
        }

        override func closeWindow(_: AdaEngine.UIWindow) {
        }

        override func showWindow(_: AdaEngine.UIWindow, isFocused _: Bool) {
        }

        override func setMinimumSize(_: Size, for _: AdaEngine.UIWindow) {
        }

        override func updateCursor() {
        }

        override func getScreen(for _: AdaEngine.UIWindow) -> Screen? {
            guard let nativeScreen = nativeView?.window?.screen else {
                return nil
            }

            return Screen(systemScreen: nativeScreen, screenManager: screenManager)
        }
    }

    final class AppleEmbeddableScreenManager: ScreenManager {
        func getMainScreen() -> Screen? {
            #if canImport(UIKit)
                return makeScreen(from: UIScreen.main)
            #elseif canImport(AppKit)
                guard let screen = NSScreen.main else {
                    return nil
                }
                return makeScreen(from: screen)
            #endif
        }

        func getScreens() -> [Screen] {
            #if canImport(UIKit)
                return UIScreen.screens.map(makeScreen(from:))
            #elseif canImport(AppKit)
                return NSScreen.screens.map(makeScreen(from:))
            #endif
        }

        func getScreenScale(for screen: Screen) -> Float {
            #if canImport(UIKit)
                return Float((screen.systemScreen as? UIScreen)?.scale ?? 1)
            #elseif canImport(AppKit)
                return Float((screen.systemScreen as? NSScreen)?.backingScaleFactor ?? 1)
            #endif
        }

        func getSize(for screen: Screen) -> Size {
            #if canImport(UIKit)
                return (screen.systemScreen as? UIScreen)?.bounds.size.toEngineSize ?? .zero
            #elseif canImport(AppKit)
                return (screen.systemScreen as? NSScreen)?.frame.size.toEngineSize ?? .zero
            #endif
        }

        func getBrightness(for screen: Screen) -> Float {
            #if canImport(UIKit)
                return Float((screen.systemScreen as? UIScreen)?.brightness ?? 1)
            #elseif canImport(AppKit)
                return 1
            #endif
        }

        func makeScreen(from systemScreen: SystemScreen) -> Screen {
            Screen(systemScreen: systemScreen, screenManager: self)
        }
    }

#endif
