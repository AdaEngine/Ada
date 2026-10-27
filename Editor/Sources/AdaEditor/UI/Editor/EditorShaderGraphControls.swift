@_spi(AdaEngine) import AdaEngine
import Foundation

/// Keep the symbol font local: enclosing text/button styles may supply their own font.
struct EditorShaderGraphSymbol: View {
    let glyph: String
    var size: Double = 16
    var body: some View {
        Text(verbatim: glyph).environment(\.font, AdaEditorMaterialSymbolFont.font(size: size))
            .frame(width: Float(size), height: Float(size))
    }
}

struct EditorShaderGraphAction: View {
    let title: String
    let glyph: String
    var selected = false
    var destructive = false
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                EditorShaderGraphSymbol(glyph: glyph)
                Text(L10n.tr(title)).lineLimit(1)
            }.foregroundColor(destructive ? .red : theme.editorColors.text)
        }.buttonStyle(EditorUIDesignerButtonStyle(colors: theme.editorColors, selected: selected, bordered: true))
    }
}

struct EditorShaderGraphSection<Content: View>: View {
    let title: String
    let glyph: String
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                EditorShaderGraphSymbol(glyph: glyph).foregroundColor(theme.editorColors.blue)
                Text(L10n.tr(title)).environment(\.font, .system(size: 12, weight: .semibold))
            }
            content()
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.background.opacity(0.45)))
            .overlay { RoundedRectangleShape(cornerRadius: 8).stroke(theme.editorColors.border.opacity(0.65), lineWidth: 1) }
    }
}

struct EditorShaderGraphTypeBadge: View {
    let type: String
    var body: some View {
        Text(verbatim: type).environment(\.font, .system(size: 10, weight: .semibold))
            .foregroundColor(EditorNodeCanvas.portColor(type)).padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangleShape(cornerRadius: 4).fill(EditorNodeCanvas.portColor(type).opacity(0.12)))
    }
}

struct EditorShaderGraphValueEditor: View {
    let model: EditorShaderGraphModel
    let node: ShaderGraph.Node
    @Environment(\.theme) private var theme
    @State private var drafts: [Int: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if node.type == .color, node.value.count == 4 {
                colorPicker
                Text(L10n.tr("Linear RGBA")).foregroundColor(theme.editorColors.muted)
            }
            if node.type == .bool {
                Toggle(L10n.text("Value"), isOn: Binding(
                    get: { (values.first ?? 0) != 0 },
                    set: { value in model.editNode(node.id) { $0.value = [value ? 1 : 0] } }
                )).accessibilityIdentifier("AdaEditor.ShaderGraph.Value.0")
            } else if !node.value.isEmpty {
                HStack(spacing: 6) {
                    ForEach(0..<node.value.count, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: channel(index)).environment(\.font, .system(size: 10, weight: .semibold))
                                .foregroundColor(theme.editorColors.muted)
                            EditorUIDesignerField(placeholder: "", text: Binding(
                                get: { drafts[index] ?? String(format: "%.5g", values.indices.contains(index) ? values[index] : 0) },
                                set: { text in
                                    drafts[index] = text
                                    guard let value = Float(text), value.isFinite else { return }
                                    model.editNode(node.id) { if $0.value.indices.contains(index) { $0.value[index] = value } }
                                }
                            )).accessibilityIdentifier("AdaEditor.ShaderGraph.Value.\(index)")
                        }.frame(maxWidth: .infinity)
                    }
                }
            }
        }.disabled(model.isReadOnly).onChange(of: values) { _, updated in
            for index in drafts.keys where !updated.indices.contains(index) || Float(drafts[index] ?? "") != updated[index] {
                drafts[index] = nil
            }
        }
    }

    private var values: [Float] { model.graph?.nodes.first { $0.id == node.id }?.value ?? node.value }

    private func channel(_ index: Int) -> String {
        if node.type == .color { return ["R", "G", "B", "A"][min(index, 3)] }
        if node.value.count > 1 { return ["X", "Y", "Z", "W"][min(index, 3)] }
        return L10n.tr("Value")
    }

    private var colorPicker: some View {
        let components = (values + [0, 0, 0, 1]).prefix(4)
        let value = EditorInspectorColorValue(red: components[0], green: components[1], blue: components[2], alpha: components[3])
        return Button {
            #if (canImport(AppKit) && os(macOS)) || (canImport(UIKit) && os(iOS)) || os(Windows)
            EditorPlatformColorPicker.present(value: value) { updated in
                drafts = [:]
                model.editNode(node.id) { $0.value = updated.components }
            }
            #endif
        } label: {
            HStack(spacing: 8) {
                RoundedRectangleShape(cornerRadius: 4)
                    .fill(Color(red: value.red, green: value.green, blue: value.blue, alpha: 1))
                    .frame(width: 32, height: 20)
                    .overlay { RoundedRectangleShape(cornerRadius: 4).stroke(theme.editorColors.border, lineWidth: 1) }
                Text(L10n.tr("Choose Color"))
                Spacer(minLength: 0)
                EditorShaderGraphSymbol(glyph: "\u{E3B7}")
            }.frame(maxWidth: .infinity)
        }.buttonStyle(EditorUIDesignerButtonStyle(colors: theme.editorColors, bordered: true))
            .disabled(!supportsNativePicker)
            .accessibilityIdentifier("AdaEditor.ShaderGraph.ColorPicker")
    }

    private var supportsNativePicker: Bool {
        #if (canImport(AppKit) && os(macOS)) || (canImport(UIKit) && os(iOS)) || os(Windows)
        true
        #else
        false
        #endif
    }
}
