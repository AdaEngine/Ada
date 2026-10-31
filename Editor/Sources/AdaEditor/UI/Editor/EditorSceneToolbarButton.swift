@_spi(AdaEngine) import AdaEngine

/// Compact scene actions keep their descriptions in a tooltip below the header.
struct EditorSceneToolbarButton: View {
    let title: String
    let symbol: String
    let identifier: String
    var isSelected = false
    var isEnabled = true
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Text(symbol)
                .font(AdaEditorMaterialSymbolFont.font(size: 17))
                .foregroundColor(isSelected ? theme.editorColors.blue : theme.editorColors.text)
                .frame(width: 28, height: 26)
        }
        .buttonStyle(EditorPickerRowButtonStyle(
            theme: theme,
            selectionColor: isSelected ? theme.editorColors.blue.opacity(0.14) : .clear
        ))
        .disabled(!isEnabled)
        .overlay(anchor: .topTrailing) {
            if isHovered {
                Text(L10n.tr(title))
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.text)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surfaceElevated))
                    .overlay { adaEditorPanelBorder(theme: theme, cornerRadius: 5) }
                    .offset(y: 32)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("\(identifier).Tooltip")
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityIdentifier(identifier)
    }
}
