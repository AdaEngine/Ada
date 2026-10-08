@_spi(AdaEngine) import AdaEngine

struct EditorAgentChangesSummary: View {
    let events: [EditorAgentEvent]
    let onOpenFile: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let files = EditorAgentSessionChanges.files(in: events)
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(files.count) files changed · This session")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.editorColors.text)
                ForEach(Array(files.prefix(3))) { file in
                    Button(action: { onOpenFile(file.path) }) {
                        HStack(spacing: 8) {
                            Text("\u{E24D}").font(AdaEditorMaterialSymbolFont.font(size: 15))
                            Text(file.path).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Text("Open").font(.system(size: 11))
                        }
                        .foregroundColor(theme.editorColors.blue)
                        .frame(height: 24)
                    }
                    .buttonStyle(DefaultButtonStyle())
                    .accessibilityIdentifier("AdaEditor.Agent.ChangedFile.\(file.path)")
                }
                if files.count > 3 {
                    Text("All changed files are listed under the selected session.")
                        .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                }
            }
            .padding(12)
            .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.surface))
            .overlay { RoundedRectangleShape(cornerRadius: 8).stroke(theme.editorColors.border, lineWidth: 1) }
            .padding(.horizontal, 28)
            .padding(.bottom, 6)
            .accessibilityIdentifier("AdaEditor.Agent.ChangesSummary")
        }
    }
}
