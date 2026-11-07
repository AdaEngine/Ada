@_spi(AdaEngine) import AdaEngine

struct EditorEnumField: View {
    let cases: [String]
    let selection: Binding<String>
    var accessibilityID = "AdaEditor.Enum.Toggle"
    var labels: [String: String] = [:]
    var localizesValues = true
    var compact = false
    @Environment(\.theme) private var theme

    var body: some View {
        DropDown(selection: selection, options: cases.map { .init(label: label($0), value: $0) }, identifier: accessibilityID) {
            HStack(spacing: compact ? 2 : 6) {
                let value = selection.wrappedValue
                Text(label(value)).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
                Text("\u{E5CF}").environment(\.font, AdaEditorMaterialSymbolFont.font(size: 16))
            }
            .padding(.horizontal, compact ? 4 : 8)
            .frame(height: fieldHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundColor(theme.editorColors.text)
        }
        .buttonStyle(EditorFieldButtonStyle(theme: theme))
    }

    private func label(_ value: String) -> String {
        let title = labels[value] ?? value
        return localizesValues ? L10n.tr(title) : title
    }

    private var fieldHeight: Float {
        #if IOS || VISIONOS || ANDROID
        44
        #else
        30
        #endif
    }
}

struct EditorFieldButtonStyle: ButtonStyle {
    let theme: Theme
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        let enabled = isEnabled && configuration.state.isEnabled
        let focused = configuration.state.contains(.focused)
        let feedback: Color = !enabled ? .clear : configuration.isPressed ? theme.editorColors.text.opacity(0.16)
            : configuration.isHighlighted ? theme.editorColors.text.opacity(0.10) : focused ? theme.editorColors.blue.opacity(0.12) : .clear
        return configuration.label
            .opacity(enabled ? 1 : 0.55)
            .background {
                RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surfaceElevated)
                    .overlay { RoundedRectangleShape(cornerRadius: 6).fill(feedback) }
            }
            .overlay {
                RoundedRectangleShape(cornerRadius: 6).stroke(focused ? theme.editorColors.blue : theme.editorColors.border.opacity(0.6), lineWidth: 1)
            }
    }
}
