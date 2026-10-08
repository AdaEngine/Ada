#if os(iOS)
@_spi(AdaEngine) import AdaEngine

struct MobileEditorHarnessScreen: View {
    @Environment(\.theme) private var theme
    @State private var draft = MobileAgentHarnessSettings()
    @State private var status = ""
    let store: MobileAgentHarnessStore
    let isBusy: Bool
    let showProviders: () -> Void
    let showSkills: () -> Void

    var body: some View {
        MobileEditorPageScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings for all projects on this device. Changes apply to the next agent run.")
                    .font(MobileEditorFont.font(size: 13))
                    .foregroundColor(theme.editorColors.muted)
                navigationCard("Providers & model", detail: "Connect Codex or an API provider", action: showProviders)
                    .accessibilityIdentifier("AdaEditor.Mobile.AgentProviders")
                navigationCard("Skills", detail: "\(store.settings.enabledSkills.count) enabled · Import your instructions", action: showSkills)
                    .accessibilityIdentifier("AdaEditor.Mobile.AgentSkills")
                MobileEditorCard {
                    VStack(alignment: .leading, spacing: 14) {
                        heading("Instructions")
                        detail("Tell the agent your preferred language, game style or working conventions.")
                        TextEditor(
                            "Add your instructions…",
                            text: Binding(get: { draft.instructions }, set: { draft.instructions = $0 }),
                            showsLineNumbers: false,
                            wrapsLines: true
                        )
                            .font(MobileEditorFont.font(size: 14))
                            .foregroundColor(theme.editorColors.text)
                            .frame(height: 150)
                            .frame(maxWidth: .infinity)
                            .textEditorColors(instructionColors)
                            .mask(RoundedRectangleShape(cornerRadius: 12))
                            .accessibilityIdentifier("AdaEditor.Mobile.AgentInstructions")
                    }
                    .padding(17)
                }
                .disabled(isBusy)
                MobileEditorCard {
                    VStack(alignment: .leading, spacing: 14) {
                        heading("Agent loop")
                        detail("Tool rounds per attempt. Higher limits allow longer tasks.")
                        choices([20, 80, 160], selected: draft.maxToolRounds) { draft.maxToolRounds = $0 }
                        detail("Automatic repair attempts after validation fails. Compilation, scene loading and simulation are always checked.")
                        choices([0, 1, 2], selected: draft.repairAttempts) { draft.repairAttempts = $0 }
                        Button {
                            draft.opensPreview.toggle()
                        } label: {
                            HStack {
                                Text("Open Play after success")
                                Spacer()
                                Text(draft.opensPreview ? "On" : "Off")
                                    .foregroundColor(theme.editorColors.blue)
                            }
                            .font(MobileEditorFont.font(size: 14))
                            .foregroundColor(theme.editorColors.text)
                            .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("AdaEditor.Mobile.AgentAutoPreview")
                    }
                    .padding(17)
                }
                .disabled(isBusy)
                MobileEditorPrimaryButton(title: "Save agent settings", action: save)
                    .disabled(isBusy)
                    .accessibilityIdentifier("AdaEditor.Mobile.SaveHarness")
                if isBusy { detail("Wait for the current agent run to finish before changing settings.") }
                if !status.isEmpty { detail(status).accessibilityIdentifier("AdaEditor.Mobile.HarnessStatus") }
                if let error = store.errorMessage { detail(error) }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 24)
        }
        .background(theme.editorColors.background)
        .onAppear { draft = store.settings }
    }

    private func navigationCard(_ title: String, detail subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            MobileEditorCard {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        heading(title)
                        detail(subtitle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                    Text("\u{E5CC}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 20))
                        .foregroundColor(theme.editorColors.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(17)
            }
        }
        .buttonStyle(DefaultButtonStyle())
    }

    private func choices(_ values: [Int], selected: Int, action: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            ForEach(values, id: \.self) { value in
                Button { action(value) } label: {
                    Text("\(value)")
                        .font(MobileEditorFont.font(size: 14))
                        .foregroundColor(selected == value ? theme.editorColors.blue : theme.editorColors.text)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangleShape(cornerRadius: 10).fill(
                            selected == value ? theme.editorColors.blue.opacity(0.15) : theme.editorColors.background
                        ))
                }
                .buttonStyle(DefaultButtonStyle())
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(MobileEditorFont.navigationFont(size: 18)).foregroundColor(theme.editorColors.text)
    }

    private var instructionColors: TextEditorColors {
        TextEditorColors(
            background: theme.editorColors.background,
            border: .clear,
            focusedBorder: .clear,
            gutter: .clear,
            gutterRule: .clear,
            currentLineBackground: .clear,
            selection: theme.editorColors.blue.opacity(0.24)
        )
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(MobileEditorFont.font(size: 13)).foregroundColor(theme.editorColors.muted)
    }

    private func save() {
        guard !isBusy else {
            return
        }
        do {
            var value = store.settings
            value.instructions = draft.instructions
            value.maxToolRounds = draft.maxToolRounds
            value.repairAttempts = draft.repairAttempts
            value.opensPreview = draft.opensPreview
            try store.save(value)
            status = "Saved. Settings apply to the next run."
        } catch {
            status = error.localizedDescription
        }
    }
}
#endif
