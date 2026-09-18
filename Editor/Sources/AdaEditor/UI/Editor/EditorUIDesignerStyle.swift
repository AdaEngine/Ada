@_spi(AdaEngine) import AdaEngine
import Math

enum EditorUIDesignerPane: String, CaseIterable {
    case library = "Library"
    case canvas = "Canvas"
}

struct EditorUIDesignerLayout {
    let size: Size
    var showsSidebars: Bool { size.width >= 900 }
    var toolbarHeight: Float { size.width >= 1100 ? 52 : (size.width >= 560 ? 88 : 124) }
    var sidebarWidth: Float { 220 }
    var contentHeight: Float { max(0, size.height - toolbarHeight - 29 - (showsSidebars ? 0 : 38)) }
    var canvasWidth: Float { max(0, size.width - (showsSidebars ? sidebarWidth + 1 : 0)) }

    func fitZoom(width: Float, height: Float) -> Float {
        min(1, max(0.02, min(max(0, canvasWidth - 64) / max(1, width), max(0, contentHeight - 112) / max(1, height))))
    }
}

struct EditorUIDesignerButtonStyle: ButtonStyle {
    let colors: EditorThemeColors
    var selected = false
    var bordered = false

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = configuration.state.isHighlighted || configuration.state.contains(.focused)
        return configuration.label
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundColor(colors.text)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                RoundedRectangleShape(cornerRadius: 6)
                    .fill(
                        selected ? colors.blue.opacity(0.16) : (highlighted || bordered ? colors.surfaceElevated : .clear)
                    )
            )
            .overlay {
                RoundedRectangleShape(cornerRadius: 6)
                    .stroke(highlighted ? colors.blue.opacity(0.65) : (bordered ? colors.border.opacity(0.65) : .clear), lineWidth: 1)
            }
            .opacity(configuration.state.isEnabled ? 1 : 0.38)
    }
}

struct EditorUIDesignerField: View {
    let placeholder: String
    let text: Binding<String>
    @Environment(\.theme) private var theme

    var body: some View {
        TextField(placeholder, text: text)
            .textFieldStyle(PlainTextFieldStyle())
            .font(.system(size: 12))
            .foregroundColor(theme.editorColors.text)
            .padding(.horizontal, 6)
            .frame(height: 30)
            .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surfaceElevated))
            .overlay {
                RoundedRectangleShape(cornerRadius: 6).stroke(theme.editorColors.border.opacity(0.6), lineWidth: 1)
            }
    }
}

enum EditorUIDesignerSymbols {
    static func icon(_ type: String) -> String {
        switch type {
        case "Text",
            "TextField",
            "TextEditor":
            "\u{E264}"
        case "Image": "\u{E3F4}"
        case "Button",
            "SearchBar",
            "NavigationLink":
            "\u{E913}"
        case "Divider": "\u{E15B}"
        case "Spacer": "\u{E256}"
        case "Circle",
            "Rectangle",
            "RoundedRectangle",
            "Color",
            "LinearGradient",
            "RadialGradient":
            "\u{E3B7}"
        case "HStack",
            "VStack",
            "ZStack",
            "Grid",
            "LazyVStack",
            "ScrollView",
            "Group":
            "\u{E8F1}"
        default: "\u{E8F0}"
        }
    }

    static func category(_ type: String) -> String {
        switch type {
        case "HStack",
            "VStack",
            "ZStack",
            "Grid",
            "LazyVStack",
            "ScrollView",
            "Group",
            "Spacer",
            "Divider":
            "Layout"
        case "Text",
            "TextEditor",
            "TextField",
            "Image":
            "Content"
        case "Button",
            "SearchBar",
            "NavigationLink",
            "NavigationStack":
            "Controls"
        case "Circle",
            "Rectangle",
            "RoundedRectangle",
            "Color",
            "LinearGradient",
            "RadialGradient":
            "Drawing"
        default: "Advanced"
        }
    }
}

extension EditorUISceneEditor {
    func symbol(_ code: String, size: Float = 16) -> some View {
        EditorUIDesignerSymbol(code: code, size: size)
    }

    func iconButton(_ code: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { symbol(code) }
            .buttonStyle(EditorUIDesignerButtonStyle(colors: theme.editorColors, bordered: true))
            .accessibilityIdentifier("AdaEditor.UIScene.\(title)")
    }

    func sectionTitle(_ title: String, detail: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(theme.editorColors.text)
            Spacer()
            if let detail {
                Text(detail).font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
            }
        }
        .frame(height: 20)
    }

    var panelDivider: some View {
        RectangleShape().fill(theme.editorColors.border.opacity(0.45)).frame(height: 1)
    }
}

private struct EditorUIDesignerSymbol: View {
    let code: String
    let size: Float
    @Environment(\.foregroundColor) private var foregroundColor
    @Environment(\.theme) private var theme

    var body: some View {
        var attributes = TextAttributeContainer()
        attributes.font = AdaEditorMaterialSymbolFont.font(size: Double(size))
        attributes.foregroundColor = foregroundColor ?? theme.editorColors.muted
        return Text(AttributedText(code, attributes: attributes))
            .frame(width: size + 6, height: size + 12)
    }
}
