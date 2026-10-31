@_spi(AdaEngine) import AdaEngine

/// Draws pointer and keyboard feedback over the row's persistent selection color.
struct EditorPickerRowButtonStyle: ButtonStyle {
    let theme: Theme
    var selectionColor: Color = .clear
    var cornerRadius: Float = 5

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = configuration.state.isEnabled
            && (configuration.isHighlighted || configuration.isPressed || configuration.state.contains(.focused))
        return configuration.label.background {
            RoundedRectangleShape(cornerRadius: cornerRadius)
                .fill(selectionColor)
                .overlay {
                    RoundedRectangleShape(cornerRadius: cornerRadius)
                        .fill(highlighted ? theme.editorColors.text.opacity(0.10) : .clear)
                }
        }
    }
}
