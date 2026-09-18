@_spi(AdaEngine) import AdaEngine

struct EditorThemeColors: Hashable, Sendable {
    var background: Color
    var surface: Color
    var surfaceElevated: Color
    var border: Color
    var text: Color
    var muted: Color
    var blue: Color
    var purple: Color

    static let dark = Self(
        background: Color(red: 30 / 255, green: 31 / 255, blue: 34 / 255),
        surface: Color(red: 39 / 255, green: 41 / 255, blue: 46 / 255),
        surfaceElevated: Color(red: 24 / 255, green: 25 / 255, blue: 29 / 255),
        border: Color(red: 66 / 255, green: 70 / 255, blue: 78 / 255),
        text: Color(red: 223 / 255, green: 225 / 255, blue: 229 / 255),
        muted: Color(red: 139 / 255, green: 145 / 255, blue: 155 / 255),
        blue: Color(red: 53 / 255, green: 116 / 255, blue: 240 / 255),
        purple: Color(red: 177 / 255, green: 98 / 255, blue: 241 / 255)
    )
}

private struct EditorThemeColorsKey: ThemeKey {
    static let defaultValue: EditorThemeColors = .dark
}

extension Theme {
    var editorColors: EditorThemeColors {
        get { self[EditorThemeColorsKey.self] }
        set { self[EditorThemeColorsKey.self] = newValue }
    }

    static var adaEditor: Theme {
        var theme = Theme()
        theme.editorColors = .dark
        return theme
    }
}
