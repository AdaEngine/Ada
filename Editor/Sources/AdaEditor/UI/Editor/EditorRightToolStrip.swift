@_spi(AdaEngine) import AdaEngine

struct EditorRightToolStrip: View {
    let viewModel: EditorViewModel
    let onSelectTool: (EditorToolStripItem) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: AdaEngineStyleLayoutSpec.usesCompactWorkspace ? 4 : 8) {
            ForEach(viewModel.toolStrip.rightTools, id: \.identifier) { item in
                adaEditorStripButton(
                    item,
                    active: viewModel.isRightToolPresented(item),
                    theme: theme,
                    accent: item.identifier == "swiftPackageTasks" ? theme.editorColors.purple : nil,
                    tooltipEdge: .right,
                    action: {
                        onSelectTool(item)
                    }
                )
            }
            Spacer()
        }
        .padding(.vertical, AdaEngineStyleLayoutSpec.usesCompactWorkspace ? 5 : 9)
        .background(theme.editorColors.background)
        .overlay(anchor: .leading) {
            if AdaEngineStyleLayoutSpec.usesCompactWorkspace {
                RectangleShape().fill(theme.editorColors.border).frame(width: 1).allowsHitTesting(false)
            }
        }
    }
}

struct EditorLeftToolStrip: View {
    let viewModel: EditorViewModel
    let onSelectTopTool: (EditorToolStripItem) -> Void
    let onSelectBottomTool: (EditorToolStripItem) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: AdaEngineStyleLayoutSpec.usesCompactWorkspace ? 4 : 8) {
            ForEach(viewModel.toolStrip.leftTopTools, id: \.identifier) { item in
                adaEditorStripButton(
                    item,
                    active: viewModel.isLeftTopToolPresented(item),
                    theme: theme,
                    action: {
                        onSelectTopTool(item)
                    }
                )
            }
            Spacer()
            ForEach(viewModel.toolStrip.leftBottomTools, id: \.identifier) { item in
                adaEditorStripButton(
                    item,
                    active: viewModel.isLeftBottomToolPresented(item),
                    theme: theme,
                    action: {
                        onSelectBottomTool(item)
                    }
                )
            }
        }
        .padding(.vertical, AdaEngineStyleLayoutSpec.usesCompactWorkspace ? 5 : 9)
        .background(theme.editorColors.background)
        .overlay(anchor: .trailing) {
            if AdaEngineStyleLayoutSpec.usesCompactWorkspace {
                RectangleShape().fill(theme.editorColors.border).frame(width: 1).allowsHitTesting(false)
            }
        }
    }
}
