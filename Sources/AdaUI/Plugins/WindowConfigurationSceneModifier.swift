//
//  WindowConfigurationSceneModifier.swift
//  AdaEngine
//
//  Created by Sloppy on 2026-06-08.
//

import AdaApp
import AdaECS
import AdaUtils
import Math

extension AppScene {
    /// Configure the primary native platform window using a single configuration value.
    public func window(with configuration: UIWindow.Configuration) -> some AppScene {
        self.modifier(WindowConfigurationSceneModifier(configuration: configuration))
    }
}

/// Set the complete native platform window configuration.
struct WindowConfigurationSceneModifier: SceneModifier {
    let configuration: UIWindow.Configuration

    func body(content: Content) -> some AppScene {
        content.transformAppWorlds { worlds in
            let resource = worlds.main.getRefResource(WindowSettings.self)
            resource.wrappedValue.apply(configuration)
        }
    }
}

extension WindowSettings {
    mutating func apply(_ configuration: UIWindow.Configuration) {
        self.title = configuration.title
        self.frame = configuration.frame
        self.minimumSize = configuration.minimumSize
        self.windowMode = WindowMode(configuration.mode)
        self.chrome = WindowChrome(configuration.chrome)
        self.titleBar = WindowTitleBar(configuration.titleBar)
        self.background = WindowBackground(configuration.background)
        self.backgroundEffect = WindowBackgroundEffect(configuration.backgroundEffect)
        self.level = WindowLevel(configuration.level)
        self.collectionBehavior = WindowCollectionBehavior(configuration.collectionBehavior)
        self.screenPreference = configuration.screenPreference
        self.showsImmediately = configuration.showsImmediately
        self.makeKey = configuration.makeKey
        self.hasShadow = configuration.hasShadow
        self.isResizable = configuration.isResizable
    }
}

extension WindowMode {
    init(_ mode: UIWindow.Mode) {
        switch mode {
        case .windowed:
            self = .windowed
        case .fullscreen:
            self = .fullscreen
        case .fullScreenWindowed:
            self = .fullScreenWindowed
        }
    }
}

extension WindowChrome {
    init(_ chrome: UIWindow.Chrome) {
        switch chrome {
        case .standard:
            self = .standard
        case .borderless:
            self = .borderless
        }
    }
}

extension WindowBackground {
    init(_ background: UIWindow.Background) {
        switch background {
        case let .opaque(color):
            self = .opaque(color)
        case .transparent:
            self = .transparent
        }
    }
}

extension WindowBackgroundEffect {
    init(_ effect: UIWindow.BackgroundEffect) {
        switch effect {
        case .none:
            self = .none
        case let .blur(material):
            self = .blur(Self.BlurMaterial(material))
        }
    }
}

extension WindowBackgroundEffect.BlurMaterial {
    init(_ material: UIWindow.BackgroundEffect.BlurMaterial) {
        switch material {
        case .windowBackground:
            self = .windowBackground
        case .hudWindow:
            self = .hudWindow
        case .sidebar:
            self = .sidebar
        case .popover:
            self = .popover
        case .contentBackground:
            self = .contentBackground
        case .underWindowBackground:
            self = .underWindowBackground
        #if os(macOS)
            case .glass:
                self = .glass
        #endif
        }
    }
}

extension WindowLevel {
    init(_ level: UIWindow.Level) {
        switch level {
        case .normal:
            self = .normal
        case .floating:
            self = .floating
        case .statusBar:
            self = .statusBar
        }
    }
}

extension WindowCollectionBehavior {
    init(_ behavior: UIWindow.CollectionBehavior) {
        switch behavior {
        case .standard:
            self = .standard
        case .allSpacesStationary:
            self = .allSpacesStationary
        }
    }
}

extension WindowTitleBar {
    init(_ titleBar: UIWindow.TitleBar) {
        switch titleBar.background {
        case .system:
            self.init(
                background: .system,
                reservesSafeArea: titleBar.reservesSafeArea,
                dragRegionHeight: titleBar.dragRegionHeight,
                trafficLightOffset: titleBar.trafficLightOffset
            )
        case .transparent:
            self.init(
                background: .transparent,
                reservesSafeArea: titleBar.reservesSafeArea,
                dragRegionHeight: titleBar.dragRegionHeight,
                trafficLightOffset: titleBar.trafficLightOffset
            )
        }
    }
}
