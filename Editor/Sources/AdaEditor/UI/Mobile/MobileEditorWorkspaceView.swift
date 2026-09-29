#if os(iOS)
@_spi(AdaEngine) import AdaEngine
import AdaUtils

struct MobileEditorWorkspaceView: View {
    @Environment(\.theme) private var theme
    let project: MobileEditorProject
    @Binding var selection: MobileEditorWorkspaceTab
    @Binding var promptDraft: String
    let pendingAttachmentNames: [String]
    let chatEvents: [EditorAgentEvent]
    let agentStatus: String?
    let agentActivityState: EditorAgentActivityState
    let agentActivityID: String?
    let preparePlay: () -> Void
    let onOpenFile: (String) -> Void
    let openPrompt: () -> Void

    var body: some View {
        ZStack(anchor: .bottom) {
            activeContent
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .mask(RectangleShape())
        .background(theme.editorColors.background)
        .overlay {
            EditorAgentActivityOverlay(state: agentActivityState, activityID: agentActivityID)
        }
    }

    @ViewBuilder
    private var activeContent: some View {
        TabView(selection: Binding(
            get: { selection },
            set: { tab in
                if tab == .play { preparePlay() } else { selection = tab }
            }
        )) {
            Tab("Build", value: MobileEditorWorkspaceTab.build) {
                MobileEditorBuildScreen(
                    project: project,
                    promptDraft: _promptDraft,
                    attachmentNames: pendingAttachmentNames,
                    chatEvents: chatEvents,
                    agentStatus: agentStatus,
                    isWorking: agentActivityState == .working,
                    openPrompt: openPrompt
                )
            }
            Tab("Files", value: MobileEditorWorkspaceTab.files) {
                MobileEditorFilesScreen(project: project, onOpenFile: onOpenFile)
            }
            Tab("Play", value: MobileEditorWorkspaceTab.play, placement: .floating) {
                EmptyView()
            }
        }
        .tabViewPosition(.bottom)
        .tabViewStyle(LiquidGlassTabBarStyle(
            backgroundColor: theme.editorColors.surface.opacity(0.12),
            borderColor: theme.editorColors.border,
            selectedColor: theme.editorColors.text,
            unselectedColor: theme.editorColors.muted,
            symbols: [
                "Build": "\u{E86F}",
                "Files": "\u{E2C7}",
                "Play": "\u{E037}"
            ],
            symbolFont: AdaEditorMaterialSymbolFont.font(size: 22),
            labelFont: MobileEditorFont.font(size: 11)
        ))
    }
}
struct MobileEditorBuildScreen: View {
    @Environment(\.theme) private var theme
    @Environment(\.navigationBarContentInset) private var navigationBarContentInset
    let project: MobileEditorProject
    @Binding var promptDraft: String
    let attachmentNames: [String]
    let chatEvents: [EditorAgentEvent]
    let agentStatus: String?
    let isWorking: Bool
    let openPrompt: () -> Void

    var body: some View {
        ZStack(anchor: .bottom) {
            if chatEvents.isEmpty {
                VStack(spacing: 24) {
                    Text("What would you like\nto create today?")
                        .font(MobileEditorFont.font(size: 25))
                        .foregroundColor(theme.editorColors.text)
                        .multilineTextAlignment(.center)
                    promptLauncher
                        .padding(.horizontal, 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 100)
            } else {
                transcript
                LinearGradient(
                    colors: [theme.editorColors.background.opacity(0), theme.editorColors.background.opacity(0.35)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 240)
                .allowsHitTesting(false)
                VStack(spacing: 8) {
                    if let agentStatus {
                        HStack(spacing: 6) {
                            if isWorking {
                                Circle().fill(theme.editorColors.blue).frame(width: 6, height: 6)
                            }
                            Text(agentStatus)
                        }
                            .font(MobileEditorFont.font(size: 11))
                            .foregroundColor(theme.editorColors.muted)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if isWorking {
                        Text("You can switch screens while Ada works.")
                            .font(.system(size: 11))
                            .foregroundColor(theme.editorColors.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    promptLauncher
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        var transcript = EditorAgentTranscript(events: chatEvents, sessionID: project.id.uuidString)
        transcript.contentInsets = EdgeInsets(top: 0, leading: 16, bottom: agentStatus == nil ? 220 : 260, trailing: 16)
        transcript.scrollContentInsets = EdgeInsets(top: navigationBarContentInset, leading: 0, bottom: 0, trailing: 0)
        return transcript
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private var promptLauncher: some View {
        Button(action: openPrompt) {
            EditorAgentComposerSurface(
                cornerRadius: 24,
                horizontalInset: 18,
                topInset: 14,
                bottomInset: 12,
                usesGlass: true
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(hasDraft ? promptDraft : placeholder)
                        .font(MobileEditorFont.font(size: 14))
                        .foregroundColor(hasDraft ? theme.editorColors.text : theme.editorColors.muted)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !attachmentNames.isEmpty {
                        Text(attachmentNames.joined(separator: ", "))
                            .font(MobileEditorFont.font(size: 10))
                            .foregroundColor(theme.editorColors.muted)
                            .lineLimit(1)
                    }
                    HStack(spacing: 18) {
                        Text("\u{E145}")
                            .font(AdaEditorMaterialSymbolFont.font(size: 25))
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(theme.editorColors.background.opacity(0.5)))
                        Spacer()
                        MobileEditorPromptSymbol(kind: .microphone)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(theme.editorColors.background.opacity(0.5)))
                    }
                    .foregroundColor(theme.editorColors.text)
                }
            }
        }
        .buttonStyle(DefaultButtonStyle())
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("AdaEditor.Mobile.OpenPrompt")
    }

    private var hasDraft: Bool { !promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var placeholder: String {
        project.prompt == nil ? "Create a game…" : "Describe your next change…"
    }
}

struct MobileEditorPlayEmptyScreen: View {
    @Environment(\.theme) private var theme
    let message: String?
    let showBuild: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            MobileEditorSectionHeading(eyebrow: "Play", title: "Your game will appear here")
            Text(message ?? "Build a valid AdaScript project to see it here.")
                .font(MobileEditorFont.font(size: 15))
                .foregroundColor(theme.editorColors.muted)
            MobileEditorPrimaryButton(title: "Go to Build", action: showBuild)
        }
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.editorColors.background)
    }
}
#endif
