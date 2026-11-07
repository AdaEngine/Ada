@_spi(AdaEngine) import AdaEngine

/// Shared native action appearance for the animation workspace and scene Animator.
struct EditorAnimationButtonStyle: ButtonStyle {
    let colors: EditorThemeColors
    var prominent = false
    var selected = false
    var horizontalPadding: Float = 8

    func makeBody(configuration: Configuration) -> some View {
        let enabled = configuration.state.isEnabled
        let focused = enabled && configuration.state.contains(.focused)
        let hovered = enabled && configuration.isHighlighted
        let pressed = enabled && configuration.isPressed
        let accented = prominent || selected
        return configuration.label
            .foregroundColor(accented ? colors.blue : colors.text)
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: 28)
            .background(RoundedRectangleShape(cornerRadius: 5).fill(
                accented ? colors.blue.opacity(pressed ? 0.32 : hovered ? 0.24 : 0.16)
                    : pressed ? colors.border : hovered ? colors.border.opacity(0.65) : colors.surface
            ))
            .overlay {
                RoundedRectangleShape(cornerRadius: 5)
                    .stroke(focused || accented ? colors.blue : colors.border.opacity(0.92), lineWidth: focused ? 2 : 1)
            }
            .opacity(enabled ? 1 : 0.38)
    }
}

/// Suppresses the primitive platform background, then supplies the Inspector's themed field.
struct EditorAnimationFieldStyle: TextFieldStyle {
    let colors: EditorThemeColors
    var height: Float = 28

    func _body(configuration: TextField) -> some View {
        PlainTextFieldStyle()._body(configuration: configuration)
            .font(.system(size: 11))
            .foregroundColor(colors.text)
            .padding(.horizontal, 7)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(RoundedRectangleShape(cornerRadius: 5).fill(colors.surface))
            .overlay { RoundedRectangleShape(cornerRadius: 5).stroke(colors.border.opacity(0.92), lineWidth: 1) }
    }
}

/// Uses the established scene Transform Inspector's inline axis colors and geometry.
struct EditorAnimationAxisField: View {
    let axis: String
    let text: Binding<String>
    let identifier: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Text(axis).font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                .frame(width: 24, height: 32)
                .background(RoundedRectangleShape(cornerRadius: 5).fill(axisColor))
            TextField("", text: text).textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 11, weight: .bold)).foregroundColor(theme.editorColors.text)
                .padding(.horizontal, 7).frame(minWidth: 0, maxWidth: .infinity)
                .accessibilityIdentifier(identifier)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 32, maxHeight: 32)
        .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surface))
        .overlay { RoundedRectangleShape(cornerRadius: 5).stroke(theme.editorColors.border.opacity(0.92), lineWidth: 1) }
    }

    private var axisColor: Color {
        switch axis {
        case "X": Color(red: 0.78, green: 0.24, blue: 0.28)
        case "Y": Color(red: 0.24, green: 0.60, blue: 0.31)
        case "Z": Color(red: 0.22, green: 0.43, blue: 0.82)
        case "W": Color(red: 0.57, green: 0.32, blue: 0.76)
        default: theme.editorColors.muted
        }
    }
}
