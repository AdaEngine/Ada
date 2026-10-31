@_spi(AdaEngine) import AdaEngine

extension EditorInspectorSidebar {
    func fieldGroupHeader(_ row: EditorInspectorFieldLayout.Row, namespace: String) -> some View {
        let path = row.groupPath.joined(separator: "/")
        let tint = EditorInspectorGroupColor.tint(for: "\(namespace)/\(row.id)")
        let collapsed = collapsedFieldGroups[namespace]?.contains(path) == true
        return Button(action: {
            var groups = collapsedFieldGroups[namespace] ?? []
            if !groups.insert(path).inserted { groups.remove(path) }
            collapsedFieldGroups[namespace] = groups
        }) {
            HStack(spacing: 6) {
                Text(collapsed ? "\u{E5CC}" : "\u{E5CF}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 16))
                    .foregroundColor(tint)
                Text(L10n.tr(row.title))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            .foregroundColor(theme.editorColors.text)
            .padding(.horizontal, 6)
            .frame(height: 30)
            .background(RoundedRectangleShape(cornerRadius: 5).fill(tint.opacity(0.18)))
            .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surface))
            .overlay { RoundedRectangleShape(cornerRadius: 5).stroke(tint.opacity(0.35), lineWidth: 1) }
            .padding(.leading, Float(row.level) * 10)
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.Inspector.Group.\(namespace).\(path)")
    }
}

enum EditorInspectorGroupColor {
    static func tint(for id: String) -> Color {
        // Swift's Hasher changes its seed each launch; FNV-1a keeps group colors stable.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        let hue = Float(hash % 360) / 60
        let sector = Int(hue)
        let low: Float = 0.35
        let high: Float = 0.85
        let rising = low + (high - low) * (hue - Float(sector))
        let falling = high - (rising - low)
        switch sector {
        case 0: return Color(red: high, green: rising, blue: low)
        case 1: return Color(red: falling, green: high, blue: low)
        case 2: return Color(red: low, green: high, blue: rising)
        case 3: return Color(red: low, green: falling, blue: high)
        case 4: return Color(red: rising, green: low, blue: high)
        default: return Color(red: high, green: low, blue: falling)
        }
    }
}
