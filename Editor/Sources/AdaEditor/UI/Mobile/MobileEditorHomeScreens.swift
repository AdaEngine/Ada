#if os(iOS)
@_spi(AdaEngine) import AdaEngine
import UIKit

struct MobileEditorProjectsScreen: View {
    @Environment(\.theme) private var theme
    let projects: [MobileEditorProject]
    let create: () -> Void
    let open: (MobileEditorProject) -> Void

    var body: some View {
        MobileEditorPageScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Your Worlds")
                        .font(MobileEditorFont.font(size: 34))
                        .foregroundColor(theme.editorColors.text)
                    Text("Choose a project or start a new game.")
                        .font(MobileEditorFont.font(size: 15))
                        .foregroundColor(theme.editorColors.muted)
                }

                Button(action: create) {
                    HStack(spacing: 14) {
                        Text("\u{E145}")
                            .font(AdaEditorMaterialSymbolFont.font(size: 24))
                            .foregroundColor(theme.editorColors.blue)
                            .frame(width: 48, height: 48)
                            .background(RoundedRectangleShape(cornerRadius: 14).fill(theme.editorColors.blue.opacity(0.15)))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Create Game")
                                .font(MobileEditorFont.font(size: 17))
                                .foregroundColor(theme.editorColors.text)
                            Text("Open your workspace")
                                .font(MobileEditorFont.font(size: 12))
                                .foregroundColor(theme.editorColors.muted)
                        }
                        Spacer()
                        Text("\u{E5CC}")
                            .font(AdaEditorMaterialSymbolFont.font(size: 16))
                            .foregroundColor(theme.editorColors.muted)
                    }
                    .padding(16)
                    .background(RoundedRectangleShape(cornerRadius: 18).fill(theme.editorColors.surface))
                    .overlay { RoundedRectangleShape(cornerRadius: 18).stroke(theme.editorColors.blue.opacity(0.4), lineWidth: 1) }
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.Mobile.CreateGame")

                Text("PROJECTS")
                    .font(MobileEditorFont.font(size: 11))
                    .foregroundColor(theme.editorColors.muted)
                    .padding(.top, 8)

                ForEach(projects) { project in
                    projectCard(project)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .background(theme.editorColors.background)
    }

    private func projectCard(_ project: MobileEditorProject) -> some View {
        Button {
            open(project)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                MobileEditorProjectPreviewImage(project: project, height: 160)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.title)
                            .font(MobileEditorFont.font(size: 18))
                            .foregroundColor(theme.editorColors.text)
                        Text("Open Build")
                            .font(MobileEditorFont.font(size: 13))
                            .foregroundColor(theme.editorColors.muted)
                    }
                    Spacer()
                    Text("\u{E5CC}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 16))
                        .foregroundColor(theme.editorColors.blue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.Mobile.Project.\(project.id)")
    }
}

struct MobileEditorSettingsScreen: View {
    @Environment(\.theme) private var theme
    @State private var sloppyLogo: Image?
    let agentStatus: String?
    let configureAgent: () -> Void

    var body: some View {
        MobileEditorPageScrollView {
            VStack(alignment: .leading, spacing: 22) {
                EditorCloudSettingsView()
                Button(action: configureAgent) {
                    settingsRow("Agent", detail: agentSettingsSummary, showsChevron: true)
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.Mobile.ConfigureAgent")

                HStack(spacing: 10) {
                    if let sloppyLogo {
                        sloppyLogo
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                    }
                    Text("Power by Sloppy")
                        .font(MobileEditorFont.font(size: 13))
                        .foregroundColor(theme.editorColors.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .accessibilityIdentifier("AdaEditor.Mobile.SloppyBranding")
                .onAppear {
                    guard sloppyLogo == nil,
                          let url = Bundle.editor.url(forResource: "sloppy_logo", withExtension: "png", subdirectory: "Assets/Icons") else {
                        return
                    }
                    sloppyLogo = try? Image(contentsOf: url)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .background(theme.editorColors.background)
    }

    private func settingsRow(_ title: String, detail: String, showsChevron: Bool = false) -> some View {
        MobileEditorCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(MobileEditorFont.font(size: 16))
                        .foregroundColor(theme.editorColors.text)
                    Text(detail)
                        .font(MobileEditorFont.font(size: 13))
                        .foregroundColor(theme.editorColors.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if showsChevron {
                    Text("\u{E5CC}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 18))
                        .foregroundColor(theme.editorColors.muted)
                }
            }
            .padding(17)
        }
    }

    private var agentSettingsSummary: String {
        let credentials = MobileSloppyCredentialStore.load()
        if credentials?.provider != .api, MobileCodexCredentialStore.load() != nil {
            return credentials?.model.isEmpty == false ? "Codex · \(credentials?.model ?? "")" : "Codex connected · Choose a model"
        }
        if let credentials, !credentials.apiKey.isEmpty {
            return credentials.model.isEmpty ? "OpenAI API key saved" : "\(credentials.model) configured"
        }
        if let agentStatus, !agentStatus.isEmpty { return agentStatus }
        return "Connect Codex or configure an OpenAI model"
    }
}

#endif
