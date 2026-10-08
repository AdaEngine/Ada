//
//  AdaColorPalette.swift
//  AdaEngine
//

import AdaUtils

/// Shared Ada UI color palette.
///
/// The palette contains the core dark launcher/editor surfaces, borders, text,
/// and accent colors used by Ada tooling. It lives next to ``Theme`` so these
/// design tokens can be reused across AdaUI-based apps instead of being copied
/// into individual views.
public enum AdaColorPalette {
    public static let background = Color(red: 31 / 255, green: 34 / 255, blue: 42 / 255)
    public static let window = Color(red: 40 / 255, green: 43 / 255, blue: 52 / 255)
    public static let sidebar = Color(red: 27 / 255, green: 29 / 255, blue: 36 / 255)
    public static let explorer = Color(red: 35 / 255, green: 38 / 255, blue: 46 / 255)
    public static let preview = Color(red: 48 / 255, green: 52 / 255, blue: 63 / 255)
    public static let input = Color(red: 33 / 255, green: 36 / 255, blue: 44 / 255)

    public static let inputBorder = Color.white.opacity(0.08)
    public static let glassSurface = Color.white.opacity(0.08)
    public static let glassBorder = Color.white.opacity(0.15)
    public static let muted = Color(red: 170 / 255, green: 174 / 255, blue: 186 / 255)
    public static let accentViolet = Color(red: 176 / 255, green: 91 / 255, blue: 255 / 255)
    public static let accentOrange = Color(red: 255 / 255, green: 176 / 255, blue: 79 / 255)

    public static let searchCapsuleBorder = Color.white.opacity(0.22)
    public static let searchCapsuleSurface = Color.white.opacity(0.08)
    public static let landingGlassSurface = Color.white.opacity(0.10)
    public static let landingGlassBorder = Color.white.opacity(0.26)
    public static let footerButton = Color.white.opacity(0.06)
    public static let footerButtonHighlighted = Color.white.opacity(0.12)

    public static var landingButtonGlass: Glass {
        var glass = Glass.regular
        glass.blurRadius = 22
        glass.opacity = 0.94
        glass.glassTintStrength = 0.75
        glass.glareIntensity = 0.42
        glass.tintColor = Color(red: 0.96, green: 0.98, blue: 1.0, alpha: 0.14)
        return glass
    }

    public static var searchCapsuleGlass: Glass {
        var glass = Glass.regular
        glass.blurRadius = 18
        glass.opacity = 0.92
        glass.glassTintStrength = 0.72
        glass.glareIntensity = 0.36
        glass.tintColor = Color(red: 0.96, green: 0.98, blue: 1.0, alpha: 0.12)
        return glass
    }
}

public struct AdaColorPaletteThemeKey: ThemeKey {
    public static let defaultValue = AdaColorPalette.self
}

extension Theme {
    /// Shared Ada UI color palette available through the theme container.
    public var adaColors: AdaColorPalette.Type {
        get { self[AdaColorPaletteThemeKey.self] }
        set { self[AdaColorPaletteThemeKey.self] = newValue }
    }
}
