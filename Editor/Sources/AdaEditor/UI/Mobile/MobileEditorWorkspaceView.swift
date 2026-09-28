#if os(iOS)
@_spi(AdaEngine) import AdaEngine
import AdaUtils

struct MobileEditorWorkspaceView: View {
    @Environment(\.theme) private var theme
    let project: MobileEditorProject
    @Binding var selection: MobileEditorWorkspaceTab
    @Binding var promptDraft: String
    @Binding var changeRequest: String
    @Binding var isMarkingScene: Bool
    let pendingAttachmentNames: [String]
    let chatEvents: [EditorAgentEvent]
    let agentStatus: String?
    let isAgentRunning: Bool
    let agentActivityState: EditorAgentActivityState
    let agentActivityID: String?
    let playArtifact: EditorAdaScriptProjectBuildArtifact?
    let preparePlay: () -> Void
    let onOpenFile: (String) -> Void
    let submitPrompt: () -> Void
    let showReview: () -> Void
    let goBack: () -> Void
    let pickFiles: () -> Void
    let pickPhotos: () -> Void

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
        .onChange(of: selection) { _, selected in
            if selected == .play {
                preparePlay()
            }
        }
    }

    @ViewBuilder
    private var activeContent: some View {
        TabView(selection: _selection) {
            Tab("Build", value: MobileEditorWorkspaceTab.build) {
                MobileEditorBuildScreen(
                    project: project,
                    promptDraft: _promptDraft,
                    attachmentNames: pendingAttachmentNames,
                    chatEvents: chatEvents,
                    agentStatus: agentStatus,
                    isAgentRunning: isAgentRunning,
                    submit: submitPrompt,
                    showTemplates: goBack,
                    pickFiles: pickFiles,
                    pickPhotos: pickPhotos
                )
            }
            Tab("Files", value: MobileEditorWorkspaceTab.files) {
                MobileEditorFilesScreen(project: project, onOpenFile: onOpenFile)
            }
            Tab("Play", value: MobileEditorWorkspaceTab.play, placement: .floating) {
                if project.isExample {
                    MobileEditorPreviewScreen(
                        changeRequest: _changeRequest,
                        isMarkingScene: _isMarkingScene,
                        showReview: showReview
                    )
                } else if let playArtifact, let runtimeView = try? EditorAdaScriptProjectRuntimeView(artifact: playArtifact) {
                    ZStack {
                        runtimeView
                        if playArtifact.report.systemCount == 0,
                           (playArtifact.sceneModel?.entities.count ?? 0) <= 1 {
                            Text("Create your first scene in Build")
                                .font(MobileEditorFont.font(size: 15))
                                .foregroundColor(theme.editorColors.muted)
                                .allowsHitTesting(false)
                        }
                    }
                } else {
                    MobileEditorPlayEmptyScreen(message: agentStatus) {
                        selection = .build
                    }
                }
            }
        }
        .tabViewPosition(.bottom)
        .tabViewStyle(LiquidGlassTabBarStyle(
            backgroundColor: theme.editorColors.surface,
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
private struct MobileEditorDotGrid: Shape {
    typealias AnimatableData = EmptyAnimatableData

    func path(in rect: Rect) -> Path {
        var path = Path()
        let spacing: Float = 22
        var x: Float = 10
        while x < rect.width {
            var y: Float = 10
            while y < rect.height {
                path.addEllipse(in: Rect(x: x, y: y, width: 1.2, height: 1.2))
                y += spacing
            }
            x += spacing
        }
        return path
    }
}

private struct MobileEditorIdeaHalo: Shape {
    typealias AnimatableData = EmptyAnimatableData

    func path(in rect: Rect) -> Path {
        var path = Path()
        for index in 0..<1_400 {
            let x = Float((index * 239) % 1_397) / 1_397
            let y = Float((index * 577) % 1_391) / 1_391
            let dx = (x - 0.5) * 1.3
            let dy = (y - 0.5) * 1.8
            let distance = dx * dx + dy * dy
            guard distance > 0.04, distance < 0.38 else { continue }
            path.addEllipse(in: Rect(x: x * rect.width, y: y * rect.height, width: 0.75, height: 0.75))
        }
        return path
    }
}

struct MobileEditorBuildScreen: View {
    @Environment(\.theme) private var theme
    let project: MobileEditorProject
    @Binding var promptDraft: String
    let attachmentNames: [String]
    let chatEvents: [EditorAgentEvent]
    let agentStatus: String?
    let isAgentRunning: Bool
    let submit: () -> Void
    let showTemplates: () -> Void
    let pickFiles: () -> Void
    let pickPhotos: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if chatEvents.isEmpty {
                Spacer()

                ZStack {
                    Text("What would you like\nto create today?")
                        .font(MobileEditorFont.font(size: 27))
                        .foregroundColor(theme.editorColors.text)
                        .multilineTextAlignment(.center)
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 170)

                Spacer()
            } else {
                EditorAgentTranscript(events: chatEvents, sessionID: project.id.uuidString)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }

            EditorAgentComposerSurface(
                cornerRadius: 28,
                horizontalInset: 16,
                topInset: 13,
                bottomInset: 11,
                usesGlass: false
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    EditorAgentPromptEditor(
                        text: _promptDraft,
                        placeholder: project.prompt == nil ? "Create a game…" : "Describe your next change…",
                        promptIdentifier: "AdaEditor.Mobile.BuildPrompt"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !attachmentNames.isEmpty {
                        Text(attachmentNames.joined(separator: ", "))
                            .font(MobileEditorFont.font(size: 10))
                            .foregroundColor(theme.editorColors.muted)
                            .lineLimit(1)
                    }

                    HStack {
                        Button(action: pickFiles) {
                            Text("\u{E145}")
                                .font(AdaEditorMaterialSymbolFont.font(size: 32))
                                .foregroundColor(theme.editorColors.text)
                                .frame(width: 48, height: 48)
                        }
                        .buttonStyle(DefaultButtonStyle())
                        .accessibilityIdentifier("AdaEditor.Mobile.AddFiles")

                        Button(action: pickPhotos) {
                            Text("\u{E3F4}")
                                .font(AdaEditorMaterialSymbolFont.font(size: 22))
                                .foregroundColor(theme.editorColors.text)
                                .frame(width: 44, height: 48)
                        }
                        .buttonStyle(DefaultButtonStyle())
                        .accessibilityIdentifier("AdaEditor.Mobile.AddPhotos")

                        Spacer()

                        Button(action: submit) {
                            Text("\u{E163}")
                                .font(AdaEditorMaterialSymbolFont.font(size: 22))
                                .foregroundColor(theme.editorColors.text)
                                .frame(width: 48, height: 48)
                        }
                        .buttonStyle(DefaultButtonStyle())
                        .disabled((promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachmentNames.isEmpty) || isAgentRunning)
                        .accessibilityIdentifier("AdaEditor.Mobile.BuildSubmit")
                    }
                }
            }
            .frame(maxWidth: .infinity)

            if chatEvents.isEmpty {
                Button(action: showTemplates) {
                    Text("View templates")
                        .font(MobileEditorFont.font(size: 13))
                        .foregroundColor(theme.editorColors.text)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(CapsuleShape().fill(theme.editorColors.surface))
                        .overlay {
                            CapsuleShape().stroke(theme.editorColors.border, lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.Mobile.ViewTemplates")
                .padding(.top, 28)
            }

            if let agentStatus {
                Text(agentStatus)
                    .font(MobileEditorFont.font(size: 12))
                    .foregroundColor(theme.editorColors.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 16)
            }
            if chatEvents.isEmpty {
                Spacer()
            } else {
                Color.clear.frame(height: 70)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 84)
//        .background {
//            MobileEditorDotGrid()
//                .fill(Color.white.opacity(0.12))
//                .allowsHitTesting(false)
//        }
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
