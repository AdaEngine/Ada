#if os(iOS)
@_spi(AdaEngine) import AdaEngine
import Foundation
#if canImport(SloppyRuntime)
import SloppyRuntime
#else
#error("AdaEditor iOS requires the SloppyRuntimePortable package. Set SLOPPY_RUNTIME_LOCAL_PATH to its checkout.")
#endif

struct MobileEditorProject: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var prompt: String?
    let isExample: Bool

    static let forest = MobileEditorProject(
        id: UUID(uuidString: "7B0A53A1-BCF6-40A9-9916-06AA92342509") ?? UUID(),
        title: "Foxwood",
        prompt: "Create a 2D platformer about a fox in an enchanted forest",
        isExample: true
    )
}

enum MobileEditorWorkspaceTab: Hashable {
    case build
    case files
    case play
}

private enum MobileEditorDestination: Hashable {
    case workspace(UUID)
    case settings
    case agentSettings
    case review(UUID)
}

private struct MobileEditorFilePresentation: Hashable {
    let project: MobileEditorProject
    let relativePath: String
}

struct MobileEditorRootView: View {
    @Environment(\.theme) private var theme
    @State private var navigationPath: NavigationPath = NavigationPath()
    @State private var projects: [MobileEditorProject] = MobileAdaScriptProjectService.loadProjects()
    @State private var workspaceTab: MobileEditorWorkspaceTab = .build
    @State private var promptDraft = ""
    @State private var pendingPromptAttachments: [URL] = []
    @State private var changeRequest = ""
    @State private var isMarkingScene = false
    @State private var acceptedExample = false
    @State private var sloppyRuntime = SloppyRuntimeHost()
    @State private var chatEvents: [EditorAgentEvent] = []
    @State private var activeChatProjectID: UUID?
    @State private var agentStatus: String?
    @State private var isAgentRunning = false
    @State private var agentActivityState: EditorAgentActivityState = .idle
    @State private var agentActivityID: String?
    @State private var playArtifact: EditorAdaScriptProjectBuildArtifact?
    @State private var playProjectID: UUID?
    @State private var presentedFile: MobileEditorFilePresentation?

    private let logo = ProjectOpeningAssets.loadAdaEngineLogo()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            MobileEditorProjectsScreen(projects: projects, create: createProject, open: openProject)
                .navigationTitle("Ada Studio")
                .navigationTitleFont(MobileEditorFont.navigationFont(size: 24))
                .navigationTitlePosition(.leading)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarColor(theme.editorColors.background)
                .navigationBarLeadingItems {
                    if let logo {
                        logo
                            .resizable()
                            .scaledToFit()
                            .frame(width: 32, height: 32)
                    }
                }
                .navigationBarTrailingItems {
                    Button {
                        navigationPath.append(MobileEditorDestination.settings)
                    } label: {
                        Text("\u{E8B8}")
                            .foregroundColor(theme.editorColors.text)
                            .frame(width: 40, height: 40)
                            .environment(\.font, AdaEditorMaterialSymbolFont.font(size: 24))
                    }
                    .accessibilityIdentifier("AdaEditor.Mobile.Settings")
                }
                .navigate(for: MobileEditorDestination.self, destination: destination)
        }
        .background(theme.editorColors.background.ignoresSafeArea())
        .fullScreenCover(item: $presentedFile) { request in
            MobileEditorFileCover(project: request.project, relativePath: request.relativePath)
        }
    }

    @ViewBuilder
    private func destination(_ route: MobileEditorDestination) -> some View {
        switch route {
        case .workspace(let id):
            if let project = projects.first(where: { $0.id == id }) {
                MobileEditorWorkspaceView(
                    project: project,
                    selection: $workspaceTab,
                    promptDraft: $promptDraft,
                    changeRequest: $changeRequest,
                    isMarkingScene: $isMarkingScene,
                    pendingAttachmentNames: pendingPromptAttachments.map(\.lastPathComponent),
                    chatEvents: chatEvents,
                    agentStatus: agentStatus,
                    isAgentRunning: isAgentRunning,
                    agentActivityState: agentActivityState,
                    agentActivityID: agentActivityID,
                    playArtifact: playProjectID == id ? playArtifact : nil,
                    preparePlay: { preparePlay(for: id) },
                    onOpenFile: { relativePath in
                        presentedFile = MobileEditorFilePresentation(project: project, relativePath: relativePath)
                    },
                    submitPrompt: { submitPrompt(for: id) },
                    showReview: {
                        acceptedExample = false
                        navigationPath.append(MobileEditorDestination.review(id))
                    },
                    goBack: { navigationPath.removeLast() },
                    pickFiles: pickAgentFiles,
                    pickPhotos: pickAgentPhotos
                )
                .navigationTitle(project.title)
                .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
                .navigationTitlePosition(.center)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarColor(theme.editorColors.background)
                .navigationBarTrailingItems {
                    Button {
                        navigationPath.append(MobileEditorDestination.settings)
                    } label: {
                        Text("\u{E5D4}")
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .environment(\.font, AdaEditorMaterialSymbolFont.font(size: 25))
                    }
                    .accessibilityIdentifier("AdaEditor.Mobile.WorkspaceSettings")
                }
            } else {
                Text("Project unavailable")
                    .navigationTitle("Project")
                    .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
            }
        case .settings:
            MobileEditorSettingsScreen(agentStatus: agentStatus, configureAgent: configureAgent)
                .navigationTitle("Settings")
                .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
                .navigationTitlePosition(.center)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarColor(theme.editorColors.background)
        case .agentSettings:
            MobileEditorAgentSettingsScreen()
                .navigationTitle("Providers")
                .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
                .navigationTitlePosition(.center)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarColor(theme.editorColors.background)
        case .review(let id):
            MobileEditorReviewScreen(accepted: $acceptedExample)
                .navigationTitle("Changes")
                .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
                .navigationTitlePosition(.center)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarColor(theme.editorColors.background)
                .id(id)
        }
    }

    private func createProject() {
        let project = MobileEditorProject(
            id: UUID(),
            title: "New Game \(projects.count)",
            prompt: nil,
            isExample: false
        )
        do {
            _ = try MobileAdaScriptProjectService.prepare(project)
            projects.insert(project, at: 0)
            try MobileAdaScriptProjectService.saveProjects(projects)
        } catch {
            agentStatus = error.localizedDescription
            return
        }
        openProject(project)
    }

    private func openProject(_ project: MobileEditorProject) {
        workspaceTab = .build
        promptDraft = ""
        pendingPromptAttachments = []
        changeRequest = ""
        isMarkingScene = false
        chatEvents = []
        activeChatProjectID = project.id
        agentStatus = nil
        playArtifact = nil
        playProjectID = project.id
        navigationPath.append(MobileEditorDestination.workspace(project.id))
        Task { @MainActor in await loadChat(for: project.id) }
    }

    private func preparePlay(for id: UUID) {
        guard let project = projects.first(where: { $0.id == id }), !project.isExample else { return }
        do {
            let directory = try MobileAdaScriptProjectService.prepare(project)
            playArtifact = try MobileAdaScriptProjectService.build(at: directory)
            playProjectID = id
        } catch {
            playArtifact = nil
            agentStatus = error.localizedDescription
        }
    }

    private func submitPrompt(for id: UUID) {
        let value = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!value.isEmpty || !pendingPromptAttachments.isEmpty), !isAgentRunning,
              let index = projects.firstIndex(where: { $0.id == id }) else {
            return
        }
        let credentials = MobileSloppyCredentialStore.load()
        let codexCredentials = MobileCodexCredentialStore.load()
        guard (credentials?.apiKey.isEmpty == false || codexCredentials != nil),
              let credentials, !credentials.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            agentStatus = "Configure a provider and MODEL_ID in Settings."
            return
        }
        let workspaceURL: URL
        do {
            workspaceURL = try MobileAdaScriptProjectService.prepare(projects[index])
        } catch {
            agentStatus = error.localizedDescription
            return
        }
        let attachmentPaths: [String]
        do {
            attachmentPaths = try savePromptAttachments(into: workspaceURL)
        } catch {
            agentStatus = error.localizedDescription
            return
        }
        let outgoingPrompt: String
        if attachmentPaths.isEmpty {
            outgoingPrompt = value
        } else {
            outgoingPrompt = value + "\n\nAttached files in the project:\n" + attachmentPaths.map { "- \($0)" }.joined(separator: "\n")
        }
        projects[index].prompt = value
        do {
            try MobileAdaScriptProjectService.saveProjects(projects)
        } catch {
            agentStatus = error.localizedDescription
            return
        }
        promptDraft = ""
        pendingPromptAttachments = []
        chatEvents.append(EditorAgentEvent(
            kind: .message,
            message: EditorAgentMessage(
                role: .user,
                segments: [EditorAgentMessageSegment(kind: .text, text: outgoingPrompt)]
            )
        ))
        agentStatus = "Agent is working…"
        isAgentRunning = true
        agentActivityState = .working
        let activityID = UUID().uuidString
        agentActivityID = activityID
        let streamID = "stream-\(UUID().uuidString)"
        Task { @MainActor in
            do {
                if let codexCredentials {
                    try await sloppyRuntime.configureCodex(
                        tokenProvider: { MobileCodexCredentialStore.load()?.accessToken ?? "" },
                        accountID: codexCredentials.accountID,
                        model: credentials.model,
                        refreshIfNeeded: { try await MobileCodexOAuth.refresh(force: false) },
                        refreshAfterInvalidToken: { try await MobileCodexOAuth.refresh(force: true) }
                    )
                } else {
                    try await sloppyRuntime.configureOpenAI(apiKey: credentials.apiKey, model: credentials.model, apiURL: credentials.apiURL)
                }
                _ = try await sloppyRuntime.send(
                    prompt: outgoingPrompt,
                    sessionID: id.uuidString,
                    workspaceURL: workspaceURL,
                    build: {
                        await MainActor.run {
                            MobileAdaScriptProjectService.buildForAgent(at: workspaceURL)
                        }
                    },
                    onText: { text in
                        await MainActor.run {
                            guard activeChatProjectID == id, !text.isEmpty else { return }
                            let event = EditorAgentEvent(
                                id: streamID,
                                kind: .message,
                                message: EditorAgentMessage(
                                    role: .assistant,
                                    segments: [EditorAgentMessageSegment(kind: .text, text: text)]
                                )
                            )
                            if let index = chatEvents.firstIndex(where: { $0.id == streamID }) {
                                chatEvents[index] = event
                            } else {
                                chatEvents.append(event)
                            }
                        }
                    }
                )
                _ = try MobileAdaScriptProjectService.build(at: workspaceURL)
                agentStatus = "AdaScript build succeeded"
                agentActivityState = .completed
            } catch {
                agentStatus = error.localizedDescription
                agentActivityState = .failed
            }
            await loadChat(for: id)
            isAgentRunning = false
        }
    }

    private func loadChat(for id: UUID) async {
        do {
            let directory = try MobileAdaScriptProjectService.projectURL(for: id)
            let messages = try await sloppyRuntime.messages(workspaceURL: directory)
            guard activeChatProjectID == id else { return }
            chatEvents = MobileSloppyChatAdapter.events(from: messages)
        } catch {
            if activeChatProjectID == id {
                agentStatus = error.localizedDescription
            }
        }
    }

    private func configureAgent() {
        navigationPath.append(MobileEditorDestination.agentSettings)
    }

    private func pickAgentFiles() {
        ProjectOpenPicker.presentAgentContextPicker { result in
            handleAgentAttachmentPickerResult(result)
        }
    }

    private func pickAgentPhotos() {
        ProjectOpenPicker.presentAgentPhotoPicker { result in
            handleAgentAttachmentPickerResult(result)
        }
    }

    private func handleAgentAttachmentPickerResult(_ result: AssetFilePickerResult) {
        switch result {
        case let .selected(urls):
            pendingPromptAttachments.append(contentsOf: urls.filter { url in
                !pendingPromptAttachments.contains(where: { $0.standardizedFileURL == url.standardizedFileURL })
            })
        case .cancelled:
            break
        case let .unavailable(message):
            agentStatus = message
        }
    }

    private func savePromptAttachments(into workspaceURL: URL) throws -> [String] {
        guard !pendingPromptAttachments.isEmpty else { return [] }
        let directory = workspaceURL.appendingPathComponent("Assets/AgentAttachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try pendingPromptAttachments.map { sourceURL in
            let name = "\(UUID().uuidString)-\(sourceURL.lastPathComponent)"
            let destinationURL = directory.appendingPathComponent(name)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return "Assets/AgentAttachments/\(name)"
        }
    }

}
#endif
