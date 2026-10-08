//
//  ScreenManager.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/27/23.
//

import AdaUtils
import Math

public protocol ScreenManager: AnyObject {
    func getMainScreen() -> Screen?

    func getScreens() -> [Screen]

    func getScreenScale(for screen: Screen) -> Float

    func getSize(for screen: Screen) -> Size

    func getBrightness(for screen: Screen) -> Float

    func makeScreen(from systemScreen: SystemScreen) -> Screen
}
