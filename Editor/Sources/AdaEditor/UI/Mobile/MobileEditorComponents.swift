#if os(iOS)
@_spi(AdaEngine) import AdaEngine
import Foundation

enum MobileEditorFont {
    private static let monoResource: FontResource? = {
        guard let url = Bundle.editor.url(
            forResource: "JetBrainsMono-Regular",
            withExtension: "ttf",
            subdirectory: "Assets/Fonts"
        ) else {
            return nil
        }
        return FontResource.custom(fontPath: url)
    }()

    static func font(size: Double) -> Font {
        guard let monoResource else { return .system(size: size) }
        return Font(fontResource: monoResource, pointSize: size)
    }

    static func navigationFont(size: Double) -> Font {
        AdaEditorTitleFont.font(size: size)
    }
}

struct MobileEditorCard<Content: View>: View {
    @Environment(\.theme) private var theme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(RoundedRectangleShape(cornerRadius: 18).fill(theme.editorColors.surface))
            .overlay {
                RoundedRectangleShape(cornerRadius: 18)
                    .stroke(theme.editorColors.border.opacity(0.7), lineWidth: 1)
            }
    }
}

struct MobileEditorPrimaryButton: View {
    @Environment(\.theme) private var theme
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(MobileEditorFont.font(size: 16))
                Spacer()
                Text("\u{E5CC}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 20))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangleShape(cornerRadius: 15).fill(theme.editorColors.blue))
        }
        .buttonStyle(DefaultButtonStyle())
    }
}

struct MobileEditorSectionHeading: View {
    @Environment(\.theme) private var theme
    let eyebrow: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased())
                .font(MobileEditorFont.font(size: 11))
                .foregroundColor(theme.editorColors.blue)
            Text(title)
                .font(MobileEditorFont.font(size: 31))
                .foregroundColor(theme.editorColors.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }
}

struct MobileEditorForestImage: View {
    @Environment(\.theme) private var theme
    let height: Float

    var body: some View {
        ZStack {
            theme.editorColors.surfaceElevated
            if let image = MobileEditorAssets.forestPreview {
                image
                    .resizable()
                    .aspectRatio(1.4, contentMode: .fill)
            } else {
                Text("Foxwood")
                    .font(MobileEditorFont.font(size: 24))
                    .foregroundColor(theme.editorColors.text)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .mask(RoundedRectangleShape(cornerRadius: 18))
        .overlay {
            RoundedRectangleShape(cornerRadius: 18)
                .stroke(theme.editorColors.border.opacity(0.7), lineWidth: 1)
        }
    }
}
#endif
