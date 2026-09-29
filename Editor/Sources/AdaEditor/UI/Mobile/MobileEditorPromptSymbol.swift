#if os(iOS)
@_spi(AdaEngine) import AdaEngine

struct MobileEditorPromptSymbol: View {
    enum Kind {
        case microphone
        case expand
        case collapse

        var glyph: String {
            switch self {
            case .microphone: "\u{E029}"
            case .expand: "\u{E5D0}"
            case .collapse: "\u{E5D1}"
            }
        }
    }

    @Environment(\.theme) private var theme
    let kind: Kind

    var body: some View {
        Text(kind.glyph)
            .font(Self.symbolFont)
            .foregroundColor(theme.editorColors.text)
            .frame(width: 24, height: 24)
    }

    private static let symbolFont: Font = {
        guard let url = Foundation.Bundle.editor.url(
            forResource: "MaterialSymbolsRounded-Prompt",
            withExtension: "ttf",
            subdirectory: "Assets/Fonts"
        ) else {
            return AdaEditorMaterialSymbolFont.font(size: 24)
        }
        guard let resource = FontResource.custom(
            fontPath: url,
            emFontScale: 96,
            includeDefaultCharset: false,
            additionalCodepoints: [0xE029, 0xE5D0, 0xE5D1]
        ) else {
            return AdaEditorMaterialSymbolFont.font(size: 24)
        }
        return Font(fontResource: resource, pointSize: 24)
    }()
}
#endif
