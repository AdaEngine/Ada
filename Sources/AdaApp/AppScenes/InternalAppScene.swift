//
//  InternalAppScene.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/9/23.
//

import AdaECS
import AdaUtils
import Math

/// The mode of the window.
public enum WindowMode: UInt64, Sendable {
    /// The windowed mode.
    case windowed

    /// The fullscreen mode.
    case fullscreen

    /// A platform window expanded to fill the screen without entering native exclusive fullscreen.
    case fullScreenWindowed
}

/// Preferred display for the primary platform window.
public enum WindowScreenPreference: Sendable, Equatable {
    /// Use the platform main screen.
    case main

    /// Use a screen by index in the platform screen list.
    case index(Int)

    /// Use a non-main screen by index, falling back to the platform screen list.
    case external(Int)
}

/// The title bar background behavior.
public enum WindowTitleBarBackground: Sendable, Equatable {
    /// Use the platform default title bar background.
    case system

    /// Make the title bar background transparent so app content can show through it.
    case transparent
}

/// Native platform window chrome style.
public enum WindowChrome: Sendable, Equatable {
    /// Use the platform default titled window chrome.
    case standard

    /// Use a borderless platform window.
    case borderless
}

/// Native platform window background style.
public enum WindowBackground: Sendable, Equatable {
    /// Fill the platform window background with an opaque color.
    case opaque(Color)

    /// Make the platform window background transparent.
    case transparent
}

/// Native platform window background effect.
public enum WindowBackgroundEffect: Sendable, Equatable {
    /// Do not apply a native platform background effect.
    case none

    /// Apply a native platform blur/material behind the window contents.
    case blur(BlurMaterial)

    public enum BlurMaterial: Sendable, Equatable {
        case windowBackground
        case hudWindow
        case sidebar
        case popover
        case contentBackground
        case underWindowBackground

        #if os(macOS)
            case glass
        #endif
    }
}

/// Native platform window level.
public enum WindowLevel: Sendable, Equatable {
    /// Use the platform normal window level.
    case normal

    /// Keep the window above normal windows.
    case floating

    /// Use a status-bar-like high window level.
    case statusBar
}

/// Native platform window collection behavior.
public enum WindowCollectionBehavior: Sendable, Equatable {
    /// Use the platform standard behavior.
    case standard

    /// Show the window on all spaces and keep it stationary.
    case allSpacesStationary
}

/// Platform title bar presentation settings.
public struct WindowTitleBar: Sendable, Equatable {
    /// The title bar background behavior.
    public var background: WindowTitleBarBackground

    /// Whether app content should reserve space for the title bar.
    public var reservesSafeArea: Bool

    /// Height of the top area that starts native window dragging.
    /// If `nil`, the platform title bar height is used when available.
    public var dragRegionHeight: Float?

    /// Offset applied to macOS traffic light buttons. Positive `x` moves right, positive `y` moves down.
    public var trafficLightOffset: Point?

    /// Use the platform default title bar.
    public static let standard = Self(background: .system, reservesSafeArea: true, dragRegionHeight: nil, trafficLightOffset: nil)

    /// Make the title bar background transparent while keeping its safe area reserved.
    public static let transparent = Self(background: .transparent, reservesSafeArea: true, dragRegionHeight: nil, trafficLightOffset: nil)

    /// Make the title bar transparent and let content extend into its safe area.
    public static let overlay = Self(background: .transparent, reservesSafeArea: false, dragRegionHeight: 52, trafficLightOffset: nil)

    public init(
        background: WindowTitleBarBackground,
        reservesSafeArea: Bool = true,
        dragRegionHeight: Float? = nil,
        trafficLightOffset: Point? = nil
    ) {
        self.background = background
        self.reservesSafeArea = reservesSafeArea
        self.dragRegionHeight = dragRegionHeight
        self.trafficLightOffset = trafficLightOffset
    }
}

/// Primary Window parameters.
public struct WindowSettings: Resource {
    /// The minimum size of the window.
    public var minimumSize: Size = Size(width: 800, height: 600)

    /// Initial window content frame. If zero, the platform window manager uses `minimumSize`.
    public var frame: Rect = .zero

    /// The mode of the window.
    public var windowMode: WindowMode = .fullscreen

    /// Whether the window is a single window.
    public var isSingleWindow: Bool = false

    /// The title of the window.
    public var title: String?

    /// Whether the native platform window should draw a drop shadow.
    public var hasShadow: Bool = true

    /// Whether users can resize the native platform window.
    public var isResizable: Bool = true

    /// Platform title bar presentation settings.
    public var titleBar: WindowTitleBar = .standard

    /// Native platform window chrome style.
    public var chrome: WindowChrome = .standard

    /// Native platform window background style.
    public var background: WindowBackground = .opaque(.black)

    /// Native platform window background effect.
    public var backgroundEffect: WindowBackgroundEffect = .none

    /// Native platform window level.
    public var level: WindowLevel = .normal

    /// Native platform window collection behavior.
    public var collectionBehavior: WindowCollectionBehavior = .standard

    /// Whether the platform window should be shown immediately.
    public var showsImmediately: Bool = true

    /// Whether the platform window should become key when shown.
    public var makeKey: Bool = true

    /// Preferred display for the window.
    public var screenPreference: WindowScreenPreference?
}
