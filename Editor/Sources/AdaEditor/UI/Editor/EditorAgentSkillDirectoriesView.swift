@_spi(AdaEngine) import AdaEngine

struct EditorAgentSkillDirectoriesView: View {
    let agent: EditorAgentViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Skill folders").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("+") { agent.agentSkillsDirectories.append("") }
                    .frame(width: 30, height: 28)
                    .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surface))
                    .accessibilityIdentifier("AdaEditor.Settings.SkillFolders.Add")
            }
            ForEach(Array(agent.agentSkillsDirectories.indices), id: \.self) { index in
                HStack(spacing: 8) {
                    TextField("Project-relative folder", text: agent.skillDirectoryBinding(at: index))
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.system(size: 12))
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 32)
                        .accessibilityIdentifier("AdaEditor.Settings.SkillFolders.Path.\(index)")
                    Button("−") {
                        guard agent.agentSkillsDirectories.indices.contains(index) else {
                            return
                        }
                        agent.agentSkillsDirectories.remove(at: index)
                    }
                    .frame(width: 30, height: 28)
                    .accessibilityIdentifier("AdaEditor.Settings.SkillFolders.Remove.\(index)")
                }
                .padding(.horizontal, 10)
                .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
                .overlay { RoundedRectangleShape(cornerRadius: 6).stroke(theme.editorColors.border, lineWidth: 1) }
            }
            if agent.agentSkillsDirectories.isEmpty {
                Text("No additional skill folders.").font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
            }
        }
        .foregroundColor(theme.editorColors.text)
        .buttonStyle(DefaultButtonStyle())
    }
}
