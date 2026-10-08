//
//  AdaColorPaletteTests.swift
//  AdaEngine
//

import Testing
@testable import AdaUI
@testable import AdaUtils

@Suite("Ada color palette")
struct AdaColorPaletteTests {
    @Test("palette exposes launcher surface colors")
    func exposesLauncherSurfaceColors() {
        #expect(AdaColorPalette.background == Color(red: 31 / 255, green: 34 / 255, blue: 42 / 255))
        #expect(AdaColorPalette.window == Color(red: 40 / 255, green: 43 / 255, blue: 52 / 255))
        #expect(AdaColorPalette.sidebar == Color(red: 27 / 255, green: 29 / 255, blue: 36 / 255))
        #expect(AdaColorPalette.explorer == Color(red: 35 / 255, green: 38 / 255, blue: 46 / 255))
        #expect(AdaColorPalette.preview == Color(red: 48 / 255, green: 52 / 255, blue: 63 / 255))
        #expect(AdaColorPalette.input == Color(red: 33 / 255, green: 36 / 255, blue: 44 / 255))
    }

    @Test("palette exposes launcher text, border, and accent colors")
    func exposesLauncherTextBorderAndAccentColors() {
        #expect(AdaColorPalette.inputBorder == Color.white.opacity(0.08))
        #expect(AdaColorPalette.glassSurface == Color.white.opacity(0.08))
        #expect(AdaColorPalette.glassBorder == Color.white.opacity(0.15))
        #expect(AdaColorPalette.muted == Color(red: 170 / 255, green: 174 / 255, blue: 186 / 255))
        #expect(AdaColorPalette.accentViolet == Color(red: 176 / 255, green: 91 / 255, blue: 255 / 255))
        #expect(AdaColorPalette.accentOrange == Color(red: 255 / 255, green: 176 / 255, blue: 79 / 255))
    }

    @Test("theme exposes Ada palette accessor")
    func themeExposesAdaPaletteAccessor() {
        let theme = Theme()

        #expect(theme.adaColors.background == AdaColorPalette.background)
        #expect(theme.adaColors.accentViolet == AdaColorPalette.accentViolet)
    }

    @Test("palette exposes glass configurations")
    func exposesGlassConfigurations() {
        let landingGlass = AdaColorPalette.landingButtonGlass
        #expect(landingGlass.blurRadius == 22)
        #expect(landingGlass.opacity == 0.94)
        #expect(landingGlass.glassTintStrength == 0.75)
        #expect(landingGlass.glareIntensity == 0.42)
        #expect(landingGlass.tintColor == Color(red: 0.96, green: 0.98, blue: 1.0, alpha: 0.14))

        let searchGlass = AdaColorPalette.searchCapsuleGlass
        #expect(searchGlass.blurRadius == 18)
        #expect(searchGlass.opacity == 0.92)
        #expect(searchGlass.glassTintStrength == 0.72)
        #expect(searchGlass.glareIntensity == 0.36)
        #expect(searchGlass.tintColor == Color(red: 0.96, green: 0.98, blue: 1.0, alpha: 0.12))
    }
}
