@_spi(AdaEngine) import AdaEngine

enum AdaEditorTitleFont {
    private static let resource: FontResource? = {
        guard
            let fontURL = Foundation.Bundle.editor.url(
                forResource: "CalSans-Regular",
                withExtension: "ttf",
                subdirectory: "Assets/Fonts"
            )
        else {
            return nil
        }

        return FontResource.custom(fontPath: fontURL)
    }()

    static func font(size: Double) -> Font {
        guard let resource else {
            return .system(size: size)
        }

        return Font(fontResource: resource, pointSize: size)
    }
}

@MainActor
func adaEditorPanelTitle(_ title: String, trailing: String, theme: Theme) -> some View {
    let colors = theme.editorColors
    return HStack(spacing: 8) {
        Text(title)
            .font(.system(size: 12))
            .foregroundColor(colors.muted)
            .lineLimit(1)
        if !trailing.isEmpty {
            Text(trailing)
                .font(.system(size: 11))
                .foregroundColor(colors.muted)
                .lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        } else {
            Spacer()
        }
    }
    .padding(.horizontal, 12)
    .frame(height: 34)
}

@MainActor
func adaEditorInspectorTitle(theme: Theme) -> some View {
    HStack {
        Text("Inspector")
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(theme.editorColors.text)
        Spacer()
    }
    .padding(.horizontal, 12)
    .frame(height: 34)
}

@MainActor
func adaEditorToolbarPill(_ text: String, active: Bool, theme: Theme) -> some View {
    let colors = theme.editorColors
    return Text(text)
        .font(.system(size: 12))
        .foregroundColor(active ? colors.blue : colors.text)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangleShape(cornerRadius: 7).fill(active ? colors.blue.opacity(0.16) : colors.background))
        .overlay { RoundedRectangleShape(cornerRadius: 7).stroke(colors.border, lineWidth: 1) }
}

@MainActor
func adaEditorStripButton(
    _ item: EditorToolStripItem,
    active: Bool,
    theme: Theme,
    accent: Color? = nil,
    tooltipEdge: EditorToolStripTooltipEdge = .left,
    action: @escaping () -> Void = {}
) -> some View {
    EditorToolStripButton(
        item: item,
        active: active,
        theme: theme,
        accent: accent,
        tooltipEdge: tooltipEdge,
        action: action
    )
}

enum EditorToolStripTooltipEdge: Equatable {
    case left
    case right
}

private struct EditorToolStripButton: View {
    let item: EditorToolStripItem
    let active: Bool
    let theme: Theme
    let accent: Color?
    let tooltipEdge: EditorToolStripTooltipEdge
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(item.icon)
                .font(AdaEditorMaterialSymbolFont.font(size: 21))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(
            AdaEditorStripButtonStyle(
                active: active,
                theme: theme,
                accent: accent
            )
        )
        .overlay {
            if isHovered {
                HStack(spacing: 8) {
                    if tooltipEdge == .left {
                        tooltipLabel
                        Spacer(minLength: 0)
                    } else {
                        Spacer(minLength: 0)
                        tooltipLabel
                    }
                }
                .frame(width: 220)
                .offset(x: tooltipEdge == .left ? 135 : -135)
                .zIndex(10)
                .allowsHitTesting(false)
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("AdaEditor.ToolStrip.\(item.identifier)")
    }

    private var tooltipLabel: some View {
        Text(item.title)
            .font(.system(size: 13))
            .foregroundColor(theme.editorColors.text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangleShape(cornerRadius: 5)
                    .fill(theme.editorColors.surfaceElevated)
            )
            .overlay {
                RoundedRectangleShape(cornerRadius: 5)
                    .stroke(theme.editorColors.border, lineWidth: 1)
            }
            .accessibilityIdentifier("AdaEditor.ToolStrip.Tooltip.\(item.identifier)")
    }
}

enum AdaEditorMaterialSymbolFont {
    static let codepoints: [UInt32] = [
        0xE7F4,
        0xE001,
        0xE034,
        0xE037,
        0xE047,
        0xE0CA,
        0xE145,
        0xE14D,
        0xE15A,
        0xE15B,
        0xE166,
        0xE256,
        0xE258,
        0xE25A,
        0xE264,
        0xE2C7,
        0xE2C8,
        0xE322,
        0xE3B7,
        0xE3E7,
        0xE3F4,
        0xE48F,
        0xE5CC,
        0xE5CD,
        0xE5CF,
        0xE5D8,
        0xE5DA,
        0xE5DB,
        0xE65F,
        0xE71C,
        0xE863,
        0xE868,
        0xE869,
        0xE86C,
        0xE86F,
        0xE871,
        0xE872,
        0xE873,
        0xE87B,
        0xE88E,
        0xE897,
        0xE89F,
        0xE8B6,
        0xE8B8,
        0xE8E2,
        0xE8F0,
        0xE8F1,
        0xE8F4,
        0xE8FF,
        0xE913,
        0xE97A,
        0xEA23,
        0xEB82,
        0xEB8E,
        0xEF42,
        0xF1C4,
        0xF720,
    ]

    private static let resource: FontResource? = {
        guard
            let fontURL = Foundation.Bundle.editor.url(
                forResource: "MaterialSymbolsRounded-Regular",
                withExtension: "ttf",
                subdirectory: "Assets/Fonts"
            )
        else {
            return nil
        }

        return FontResource.custom(
            fontPath: fontURL,
            emFontScale: 96,
            includeDefaultCharset: false,
            additionalCodepoints: codepoints
        )
    }()

    static func font(size: Double) -> Font {
        guard let resource else {
            return .system(size: size)
        }

        return Font(fontResource: resource, pointSize: size)
    }
}

private struct AdaEditorStripButtonStyle: ButtonStyle {
    let active: Bool
    let theme: Theme
    let accent: Color?

    func makeBody(configuration: Configuration) -> some View {
        let colors = theme.editorColors
        let accentColor = accent ?? colors.blue
        let isHighlighted = configuration.state.isHighlighted || configuration.state.isSelected

        return configuration.label
            .foregroundColor(active ? accentColor : (isHighlighted ? colors.text : colors.muted))
            .frame(width: 34, height: 34)
            .background(RoundedRectangleShape(cornerRadius: 7).fill(active ? accentColor.opacity(0.20) : (isHighlighted ? colors.surfaceElevated : Color.clear)))
    }
}
