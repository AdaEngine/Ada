#if os(iOS)
@_spi(AdaEngine) import AdaEngine
import AdaUtils
import Foundation

struct MobileEditorWorkspaceView: View {
    @Environment(\.theme) private var theme
    @Environment(\.navigationBarContentInset) private var navigationBarContentInset
    let project: MobileEditorProject
    @Binding var selection: MobileEditorWorkspaceTab
    @Binding var promptDraft: String
    let isComposerPresented: Bool
    let pendingAttachments: [URL]
    let chatEvents: [EditorAgentEvent]
    let sessionID: String
    var a2uiPresentation: EditorAgentA2UIPresentation? = nil
    let previousSession: MobileEditorChatSessionReference?
    let resumePreviousSession: () -> Void
    let agentStatus: String?
    let agentActivityState: EditorAgentActivityState
    let agentActivityID: String?
    let preparePlay: () -> Void
    let onOpenFile: (String) -> Void
    let openPrompt: () -> Void
    let openVoice: () -> Void

    var body: some View {
        ZStack(anchor: .bottom) {
            activeContent
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .mask(RectangleShape())
        .background(theme.editorColors.background)
        .overlay(anchor: .topLeading) {
            if selection == .build, let previousSession {
                Button(action: resumePreviousSession) {
                    HStack(spacing: 7) {
                        Text("\u{E5C4}").font(AdaEditorMaterialSymbolFont.font(size: 17))
                        Text("Back to \(previousSession.title)")
                            .font(MobileEditorFont.font(size: 12))
                            .lineLimit(1)
                    }
                    .foregroundColor(theme.editorColors.text)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Capsule().fill(theme.editorColors.surface))
                }
                .buttonStyle(DefaultButtonStyle())
                .disabled(agentActivityState == .working)
                .accessibilityIdentifier("AdaEditor.Mobile.BackToSession")
                .padding(.horizontal, 16)
                .padding(.top, navigationBarContentInset + 8)
            }
        }
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
                    isComposerPresented: isComposerPresented,
                    attachmentURLs: pendingAttachments,
                    chatEvents: chatEvents,
                    sessionID: sessionID,
                    a2uiPresentation: a2uiPresentation,
                    previousSession: previousSession,
                    agentStatus: agentStatus,
                    isWorking: agentActivityState == .working,
                    openPrompt: openPrompt,
                    openVoice: openVoice
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
    let isComposerPresented: Bool
    let attachmentURLs: [URL]
    let chatEvents: [EditorAgentEvent]
    let sessionID: String
    var a2uiPresentation: EditorAgentA2UIPresentation? = nil
    let previousSession: MobileEditorChatSessionReference?
    let agentStatus: String?
    let isWorking: Bool
    let openPrompt: () -> Void
    let openVoice: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(anchor: .bottom) {
                if chatEvents.isEmpty {
                    VStack(spacing: 24) {
                        Text("What would you like\nto create today?")
                            .font(MobileEditorFont.font(size: 25))
                            .foregroundColor(theme.editorColors.text)
                            .multilineTextAlignment(.center)
                        promptLauncher
                            .frame(width: max(0, min(620, geometry.size.width - 32)))
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
                            .frame(width: max(0, min(620, geometry.size.width - 32)))
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 100)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var transcript: some View {
        var transcript = EditorAgentTranscript(events: chatEvents, sessionID: sessionID)
        transcript.a2uiPresentation = a2uiPresentation
        transcript.contentInsets = EdgeInsets(top: previousSession == nil ? 0 : 54, leading: 16, bottom: agentStatus == nil ? 220 : 260, trailing: 16)
        transcript.scrollRespectsSafeArea = false
        transcript.scrollExtendsUnderNavigationBar = true
        return transcript
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private var promptLauncher: some View {
        MobileEditorPromptLauncher(
            promptDraft: _promptDraft,
            placeholder: project.prompt == nil ? "Create a game…" : "Describe your next change…",
            attachmentURLs: attachmentURLs,
            isWorking: isWorking,
            openPrompt: openPrompt,
            openVoice: openVoice
        )
        .opacity(isComposerPresented ? 0 : 1)
        .allowsHitTesting(!isComposerPresented)
    }
}

private struct MobileEditorPromptLauncher: View {
    @Environment(\.theme) private var theme
    @Binding var promptDraft: String
    let placeholder: String
    let attachmentURLs: [URL]
    let isWorking: Bool
    let openPrompt: () -> Void
    let openVoice: () -> Void

    var body: some View {
        EditorAgentComposerSurface(
            cornerRadius: 24,
            horizontalInset: 18,
            topInset: 14,
            bottomInset: 12,
            usesGlass: true
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: openPrompt) {
                    Text(hasDraft ? promptDraft : placeholder)
                        .font(MobileEditorFont.font(size: 14))
                        .foregroundColor(hasDraft ? theme.editorColors.text : theme.editorColors.muted)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 44)
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.Mobile.OpenPrompt")
                if !attachmentURLs.isEmpty {
                    MobileEditorAttachmentPreviews(urls: attachmentURLs)
                }
                HStack(spacing: 18) {
                    Button(action: openPrompt) {
                        Text("\u{E145}")
                            .font(AdaEditorMaterialSymbolFont.font(size: 25))
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(theme.editorColors.background.opacity(0.5)))
                    }
                    .accessibilityIdentifier("AdaEditor.Mobile.OpenPromptAttachments")
                    Spacer()
                    Button(action: openVoice) {
                        MobileEditorVoiceOrb(activity: isWorking ? .working : .idle)
                            .frame(width: 52, height: 52)
                            .allowsHitTesting(false)
                    }
                    .buttonStyle(DefaultButtonStyle())
                    .accessibilityIdentifier("AdaEditor.Mobile.OpenVoice")
                }
                .foregroundColor(theme.editorColors.text)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private var hasDraft: Bool { !promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
