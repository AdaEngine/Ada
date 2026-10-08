@_spi(AdaEngine) import AdaEngine

struct EditorUIColorField: View {
    let value: String
    var supportsAlpha = true
    let onChange: (String) -> Void
    @Environment(\.theme) private var theme

    // Use the runtime parser so named colors and alpha preview exactly as rendered.
    static func color(_ value: String) -> Color? {
        try? UIFactoryContext.color(from: value)
    }

    var body: some View {
        let color = Self.color(value) ?? .clear
        HStack(spacing: 6) {
            #if (canImport(AppKit) && os(macOS)) || (canImport(UIKit) && os(iOS))
                Button {
                    EditorPlatformColorPicker.present(value: .init(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha), supportsAlpha: supportsAlpha) {
                        onChange($0.hexString)
                    }
                } label: {
                    RectangleShape()
                        .fill(color)
                        .frame(width: 30, height: 28)
                        .overlay { RoundedRectangleShape(cornerRadius: 5).stroke(theme.editorColors.border, lineWidth: 1) }
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.UIScene.ColorPicker")
            #endif
            TextField(
                supportsAlpha ? "#RRGGBBAA" : "#RRGGBB",
                text: Binding(
                    get: { value },
                    set: { text in
                        guard Self.color(text) != nil else {
                            return
                        }
                        onChange(text)
                    }
                )
            )
            .textFieldStyle(PlainTextFieldStyle())
            .font(.system(size: 12))
            .foregroundColor(theme.editorColors.text)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
            .overlay {
                RoundedRectangleShape(cornerRadius: 6).stroke(theme.editorColors.border, lineWidth: 1)
            }
        }
    }
}
