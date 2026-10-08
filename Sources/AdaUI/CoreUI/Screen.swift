//
//  Screen.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/26/23.
//

import Foundation
import Math

/// An object represents user physical display.
///
/// `Screen` instances are immutable wrappers around platform screen identity. The
/// manager reference is installed during app bootstrap and platform managers own
/// their native synchronization/main-thread requirements.
public final class Screen: @unchecked Sendable {
    private unowned let screenManager: any ScreenManager

    /// Returns scale factor of the screen.
    public var scale: Float {
        return screenManager.getScreenScale(for: self)
    }

    /// Returns physical size of the screen.
    public var size: Size {
        screenManager.getSize(for: self)
    }

    /// Return current brightness of the screen.
    public var brightness: Float {
        return screenManager.getBrightness(for: self)
    }

    /// Contains reference to native screen.
    public private(set) weak var systemScreen: SystemScreen?

    @_spi(Internal)
    public init(systemScreen: SystemScreen, screenManager: any ScreenManager) {
        self.systemScreen = systemScreen
        self.screenManager = screenManager
    }
}

extension Screen {
    /// Protects the process-wide screen manager slot used by environment defaults
    /// and headless tests. The manager itself is still responsible for native API
    /// threading rules.
    private final class ScreenManagerStorage: @unchecked Sendable {
        private let lock = NSLock()
        private var manager: (any ScreenManager)?

        var value: (any ScreenManager)? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return manager
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                manager = newValue
            }
        }
    }

    private static let screenManagerStorage = ScreenManagerStorage()

    package static var screenManager: (any ScreenManager)? {
        get { screenManagerStorage.value }
        set { screenManagerStorage.value = newValue }
    }

    /// Returns the platform primary screen.
    /// - Returns: Returns the main screen or nil if we run in headless mode.
    public static var main: Screen? {
        return screenManager?.getMainScreen()
    }

    /// Returns list of available screens.
    public static var screens: [Screen] {
        screenManager?.getScreens() ?? []
    }
}

/// Represents platform specific screen.
public protocol SystemScreen: AnyObject {}
