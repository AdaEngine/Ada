@_spi(AdaEngine) import AdaEngine

extension ToggleStyle where Self == SwitchToggleStyle {
    static func editorSettings(colors: EditorThemeColors, minimumLabelControlSpacing: Float = 8) -> Self {
        SwitchToggleStyle(
            tint: colors.blue,
            offTint: colors.border,
            labelColor: colors.text,
            statusColor: colors.muted,
            rowBackground: colors.surface,
            rowBorder: colors.border,
            showsStateText: true,
            minimumLabelControlSpacing: minimumLabelControlSpacing,
            rowHeight: 44,
            horizontalPadding: 12
        )
    }
}
