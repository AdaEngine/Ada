@_spi(AdaEngine) import AdaEngine

struct EditorNewFileMenu: View {
    var width: Float = 756
    var height: Float = 380
    let onSelect: (EditorNewFileKind) -> Void

    @State private var search = ""
    @Environment(\.theme) private var theme

    private var columns: [[EditorNewFileGroup]] {
        let groups: [[EditorNewFileGroup]]
        if width >= 720 {
            groups = [[.adaScript, .swift], [.scenes, .shaders], [.resources]]
        } else if width >= 480 {
            groups = [[.adaScript, .scenes], [.shaders, .resources, .swift]]
        } else {
            groups = [EditorNewFileGroup.allCases]
        }
        return
            groups.map { column in
                column.filter { group in group.templates.contains { $0.matches(search) } }
            }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\u{E8B6}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 18))
                    .foregroundColor(theme.editorColors.muted)
                TextField("Search templates", text: $search)
                    .font(.system(size: 12))
                    .foregroundColor(theme.editorColors.text)
                    .textFieldStyle(PlainTextFieldStyle())
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 32, maxHeight: 32)
                    .accessibilityIdentifier("AdaEditor.NewFile.Search")
            }
            .padding(.horizontal, 10)
            .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.background))
            .padding(12)

            ScrollView(.vertical) {
                if EditorNewFileKind.allCases.contains(where: { $0.matches(search) }) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { column in
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(column.element, id: \.self) { group in
                                    templateGroup(group)
                                }
                            }
                            .frame(width: (width - 24 - Float(columns.count - 1) * 16) / Float(columns.count), alignment: .topLeading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                } else {
                    Text("No templates match your search.")
                        .font(.system(size: 12))
                        .foregroundColor(theme.editorColors.muted)
                        .padding(20)
                        .accessibilityIdentifier("AdaEditor.NewFile.NoResults")
                }
            }
            .frame(width: width, height: max(0, height - 56), alignment: .topLeading)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .accessibilityIdentifier("AdaEditor.ProjectTree.New.Menu")
    }

    private func templateGroup(_ group: EditorNewFileGroup) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(group.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.editorColors.muted)
                RectangleShape().fill(theme.editorColors.border.opacity(0.6)).frame(height: 1)
            }
            .frame(height: 22)
            .accessibilityIdentifier("AdaEditor.NewFile.Group.\(group.rawValue)")
            ForEach(group.templates.filter { $0.matches(search) }, id: \.self) { kind in
                Button {
                    onSelect(kind)
                } label: {
                    HStack(spacing: 10) {
                        Text(kind.icon)
                            .font(AdaEditorMaterialSymbolFont.font(size: 22))
                            .foregroundColor(kind.tint)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangleShape(cornerRadius: 7).fill(kind.tint.opacity(0.10)))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.title)
                                .font(.system(size: 12))
                                .foregroundColor(theme.editorColors.text)
                                .lineLimit(1)
                            Text(kind.detail)
                                .font(.system(size: 10))
                                .foregroundColor(theme.editorColors.muted)
                                .lineLimit(1)
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 48)
                }
                .buttonStyle(EditorTemplateButtonStyle(theme: theme))
                .accessibilityIdentifier("AdaEditor.ProjectTree.New.\(kind.rawValue)")
            }
        }
    }
}

private struct EditorTemplateButtonStyle: ButtonStyle {
    let theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangleShape(cornerRadius: 6)
                    .fill(
                        configuration.state.isHighlighted || configuration.state.isSelected ? theme.editorColors.blue.opacity(0.18) : Color.clear
                    )
            )
    }
}
