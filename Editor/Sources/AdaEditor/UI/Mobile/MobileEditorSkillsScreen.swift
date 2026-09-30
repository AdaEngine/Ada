#if os(iOS)
@_spi(AdaEngine) import AdaEngine

struct MobileEditorSkillsScreen: View {
    @Environment(\.theme) private var theme
    @State private var status = ""
    let store: MobileAgentHarnessStore
    let isBusy: Bool
    let showSkill: (String) -> Void

    var body: some View {
        MobileEditorPageScrollView {
            VStack(alignment: .leading, spacing: 20) {
                detail("Enabled skills are included in every agent run. Import a standalone SKILL.md or Markdown file from Files. Supporting scripts and folders are not imported.")
                MobileEditorPrimaryButton(title: "Install skill from Files", action: install)
                    .disabled(isBusy)
                    .accessibilityIdentifier("AdaEditor.Mobile.InstallSkill")
                Text("BUILT-IN").font(MobileEditorFont.font(size: 11)).foregroundColor(theme.editorColors.muted)
                ForEach(MobileAgentHarnessSkill.builtIns) { skill in skillCard(skill, removable: false) }
                Text("INSTALLED").font(MobileEditorFont.font(size: 11)).foregroundColor(theme.editorColors.muted)
                if store.settings.installedSkills.isEmpty { detail("No custom skills installed yet.") }
                ForEach(store.settings.installedSkills) { skill in skillCard(skill, removable: true) }
                if isBusy { detail("Skills can be changed after the current agent run finishes.") }
                if !status.isEmpty { detail(status).accessibilityIdentifier("AdaEditor.Mobile.SkillStatus") }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 24)
        }
        .background(theme.editorColors.background)
    }

    private func skillCard(_ skill: MobileAgentHarnessSkill, removable: Bool) -> some View {
        let enabled = !store.settings.disabledSkillIDs.contains(skill.id)
        return MobileEditorCard {
            VStack(alignment: .leading, spacing: 10) {
                Button { showSkill(skill.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(skill.name).font(MobileEditorFont.navigationFont(size: 18)).foregroundColor(theme.editorColors.text)
                        detail(skill.summary)
                        Text("Read instructions").font(MobileEditorFont.font(size: 13)).foregroundColor(theme.editorColors.blue)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(DefaultButtonStyle())
                HStack {
                    Button(enabled ? "Enabled" : "Disabled") {
                        perform { try store.setEnabled(!enabled, skillID: skill.id) }
                    }
                    .foregroundColor(enabled ? theme.editorColors.blue : theme.editorColors.muted)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("AdaEditor.Mobile.SkillToggle.\(skill.id)")
                    Spacer()
                    if removable {
                        Button("Remove") { perform { try store.remove(skillID: skill.id) } }
                            .foregroundColor(theme.editorColors.muted)
                            .frame(minHeight: 44)
                    }
                }
                .font(MobileEditorFont.font(size: 14))
                .disabled(isBusy)
            }
            .padding(17)
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(MobileEditorFont.font(size: 13)).foregroundColor(theme.editorColors.muted)
    }

    private func perform(_ action: () throws -> Void) {
        guard !isBusy else {
            return
        }
        do { try action(); status = "Saved. Skills apply to the next run." } catch { status = error.localizedDescription }
    }

    private func install() {
        guard !isBusy else {
            return
        }
        ProjectOpenPicker.presentAgentContextPicker { result in
            switch result {
            case .selected(let urls):
                var installed: [String] = []
                var errors: [String] = []
                for url in urls {
                    do { installed.append(try store.install(from: url).name) } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                }
                status = ([installed.isEmpty ? "" : "Installed: \(installed.joined(separator: ", "))"] + errors).filter { !$0.isEmpty }.joined(separator: "\n")
            case .cancelled: break
            case .unavailable(let message): status = message
            }
        }
    }
}

struct MobileEditorSkillDetailScreen: View {
    @Environment(\.theme) private var theme
    let skill: MobileAgentHarnessSkill

    var body: some View {
        MobileEditorPageScrollView {
            Text(skill.content)
                .font(MobileEditorFont.font(size: 14))
                .foregroundColor(theme.editorColors.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
        }
        .background(theme.editorColors.background)
    }
}
#endif
