@_spi(AdaEngine) import AdaEngine

struct EditorUIArgumentModePicker: View {
    let isBinding: Bool
    let parameterName: String
    let onSelect: (Bool) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            modeButton("Value", binding: false)
            modeButton("Binding", binding: true)
        }
        .padding(2)
        .frame(width: 126)
        .background(RoundedRectangleShape(cornerRadius: 7).fill(theme.editorColors.background))
        .overlay { RoundedRectangleShape(cornerRadius: 7).stroke(theme.editorColors.border, lineWidth: 1) }
    }

    private func modeButton(_ title: String, binding: Bool) -> some View {
        Button {
            onSelect(binding)
        } label: {
            Text(title)
                .font(.system(size: 10, weight: isBinding == binding ? .semibold : .regular))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(EditorUIArgumentModeStyle(colors: theme.editorColors, selected: isBinding == binding))
        .accessibilityIdentifier("AdaEditor.UIScene.\(binding ? "Binding" : "Value").\(parameterName)")
    }
}

private struct EditorUIArgumentModeStyle: ButtonStyle {
    let colors: EditorThemeColors
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = configuration.state.isHighlighted || configuration.state.contains(.focused)
        return configuration.label
            .foregroundColor(selected ? colors.text : colors.muted)
            .frame(height: 26)
            .background(
                RoundedRectangleShape(cornerRadius: 5)
                    .fill(
                        selected ? colors.blue.opacity(0.30) : (highlighted ? colors.surfaceElevated : .clear)
                    )
            )
            .overlay {
                RoundedRectangleShape(cornerRadius: 5)
                    .stroke(selected || highlighted ? colors.blue.opacity(0.75) : .clear, lineWidth: 1)
            }
    }
}
