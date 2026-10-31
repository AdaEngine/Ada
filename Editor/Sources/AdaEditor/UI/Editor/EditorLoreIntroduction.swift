@_spi(AdaEngine) import AdaEngine
import Foundation

enum EditorLoreInformation {
    static let documentationURL = "https://epicgames.github.io/lore/"
}

struct EditorLoreIntroduction: View {
    var openURL: @MainActor (URL) -> Bool = EditorPlatformFileActions.openInDefaultApplication
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("Lore is open source version control from Epic Games for code and large game assets."))
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.text("About Lore and getting started")) {
                if let url = URL(string: EditorLoreInformation.documentationURL) { _ = openURL(url) }
            }
            .font(.system(size: 11))
            .foregroundColor(theme.editorColors.blue)
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.Lore.LearnMore")
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
        .accessibilityIdentifier("AdaEditor.Lore.Introduction")
    }
}
