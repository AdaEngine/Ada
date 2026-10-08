//
//  MacOSScreenManager.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/27/23.
//

#if MACOS
    @_spi(Internal) import AdaUI
    import AppKit
    import IOKit
    import Math

    class MacOSScreenManager: ScreenManager {
        func getScreens() -> [Screen] {
            return NSScreen.screens.map(makeScreen(from:))
        }

        func getMainScreen() -> Screen? {
            return activeScreen().flatMap(makeScreen(from:))
        }

        func makeScreen(from systemScreen: SystemScreen) -> Screen {
            Screen(
                systemScreen: systemScreen as! NSScreen,
                screenManager: self
            )
        }

        func getSize(for screen: Screen) -> Size {
            return (screen.systemScreen as? NSScreen)?.frame.toEngineRect.size ?? .zero
        }

        func getScreenScale(for screen: Screen) -> Float {
            let scale = Float((screen.systemScreen as? NSScreen)?.backingScaleFactor ?? 0.0)
            return max(1.0, scale)
        }

        func primaryScreen() -> NSScreen? {
            return NSScreen.screens.first ?? NSScreen.main
        }

        func activeScreen() -> NSScreen? {
            return NSScreen.main ?? primaryScreen()
        }

        func screen(containing windowFrame: NSRect) -> NSScreen? {
            let screens = NSScreen.screens
            guard !screens.isEmpty else {
                return nil
            }

            let bestMatch =
                screens
                .map { screen in (screen, screen.frame.intersectionArea(with: windowFrame)) }
                .max { lhs, rhs in lhs.1 < rhs.1 }

            guard let bestMatch, bestMatch.1 > 0 else {
                return nil
            }

            return bestMatch.0
        }

        // FIXME: Currently returns birghtness for first screen
        func getBrightness(for _: Screen) -> Float {
            var iterator: io_iterator_t = 0
            var service: io_object_t = 1
            var brighntess: Float = 1.0

            guard let dict = unsafe IOServiceMatching("IODisplayConnect") else {
                return brighntess
            }
            let result = unsafe IOServiceGetMatchingServices(kIOMainPortDefault, dict, &iterator)
            if result == KERN_SUCCESS {
                while service != 0 {
                    service = IOIteratorNext(iterator)
                    unsafe IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &brighntess)
                    IOObjectRelease(service)
                }
            }

            return brighntess
        }
    }

    @_spi(Internal)
    extension NSScreen: SystemScreen {}

    private extension NSRect {
        func intersectionArea(with rect: NSRect) -> CGFloat {
            let intersection = self.intersection(rect)
            guard !intersection.isNull, !intersection.isEmpty else {
                return 0
            }

            return intersection.width * intersection.height
        }
    }

#endif
