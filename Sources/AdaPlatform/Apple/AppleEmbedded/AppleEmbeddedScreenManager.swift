//
//  AppleEmbeddedScreenManager.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/27/23.
//

#if canImport(UIKit)
    @_spi(Internal) import AdaUI
    import Math
    import UIKit

    final class AppleEmbeddedScreenManager: ScreenManager, @unchecked Sendable {
        func getMainScreen() -> Screen? {
            MainActor.assumeIsolated {
                return makeScreen(from: UIScreen.main)
            }
        }

        func getScreens() -> [Screen] {
            MainActor.assumeIsolated {
                UIScreen.screens.map(makeScreen(from:))
            }
        }

        func getSize(for screen: Screen) -> Size {
            MainActor.assumeIsolated {
                return (screen.systemScreen as? UIScreen)?.bounds.toEngineRect.size ?? .zero
            }
        }

        func getScreenScale(for screen: Screen) -> Float {
            MainActor.assumeIsolated {
                let scale = Float((screen.systemScreen as? UIScreen)?.nativeScale ?? 0)
                return max(1.0, scale)
            }
        }

        func makeScreen(from systemScreen: SystemScreen) -> Screen {
            Screen(systemScreen: systemScreen as! UIKit.UIScreen, screenManager: self)
        }

        func getBrightness(for screen: Screen) -> Float {
            MainActor.assumeIsolated {
                Float((screen.systemScreen as? UIScreen)?.brightness ?? 0)
            }
        }
    }

    extension UIKit.UIScreen: SystemScreen {}
#endif
