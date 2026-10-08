import AdaEngine

struct EditorBuildFileList: View {
    @Environment(\.theme) private var theme

    let viewModel: EditorViewModel
    let selection: EditorBuildFileSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(selection.title)
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
                Spacer()
                Button {
                    viewModel.presentBuildFilePicker(for: selection)
                } label: {
                    Text("\u{E145}").font(AdaEditorMaterialSymbolFont.font(size: 16)).frame(width: 30, height: 28)
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.Settings.\(selection.rawValue).Add")
            }
            VStack(alignment: .leading, spacing: 0) {
                if viewModel.buildFiles(for: selection).isEmpty {
                    Text(selection == .included ? "All project sources are included." : "No files excluded.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.editorColors.muted)
                        .padding(10)
                }
                ForEach(viewModel.buildFiles(for: selection), id: \.self) { path in
                    HStack(spacing: 8) {
                        Text(path)
                            .font(.system(size: 12))
                            .foregroundColor(theme.editorColors.text)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            viewModel.removeBuildFile(path, from: selection)
                        } label: {
                            Text("\u{E15B}").font(AdaEditorMaterialSymbolFont.font(size: 16)).frame(width: 30, height: 28)
                        }
                        .buttonStyle(DefaultButtonStyle())
                        .accessibilityIdentifier("AdaEditor.Settings.\(selection.rawValue).Remove.\(path)")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
            .overlay {
                RoundedRectangleShape(cornerRadius: 6).stroke(theme.editorColors.border, lineWidth: 1)
            }
        }
    }
}
