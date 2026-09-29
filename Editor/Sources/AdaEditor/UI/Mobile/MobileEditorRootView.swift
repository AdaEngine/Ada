#if os(iOS)
@_spi(AdaEngine) import AdaEngine
import Foundation
#if canImport(SloppyRuntime)
import SloppyRuntime
#else
#error("AdaEditor iOS requires the SloppyRuntimePortable package. Set SLOPPY_RUNTIME_LOCAL_PATH to its checkout.")
#endif

enum MobileEditorWorkspaceTab: Hashable {
    case build
    case files
    case play
}

private enum MobileEditorDestination: Hashable {
    case workspace(UUID)
    case settings
    case agentSettings
    case projectSettings(UUID)
    case sessions(UUID)
    case session(UUID, String)
}

private struct MobileEditorFilePresentation: Hashable {
    let project: MobileEditorProject
    let relativePath: String
}

private struct MobileEditorPlaySession {
    let projectID: UUID
    let runtime: EditorAdaScriptProjectRuntimeSession
    let capture: EditorProjectPreviewCapture
}

struct MobileEditorRootView: View {
    @Environment(\.theme) private var theme
    @State private var navigationPath: NavigationPath = NavigationPath()
    @State private var projects: [MobileEditorProject] = MobileAdaScriptProjectService.loadProjects()
    @State private var workspaceTab: MobileEditorWorkspaceTab = .build
    @State private var promptDraft = ""
    @State private var pendingPromptAttachments: [URL] = []
    @State private var sloppyRuntime = SloppyRuntimeHost()
    @State private var chatState = MobileEditorChatState()
    private var chatEvents: [EditorAgentEvent] {
        get { chatState.events }
        nonmutating set { chatState.events = newValue }
    }
    private var activeChatProjectID: UUID? {
        get { chatState.activeProjectID }
        nonmutating set { chatState.activeProjectID = newValue }
    }
    private var agentStatus: String? {
        get { chatState.status }
        nonmutating set { chatState.status = newValue }
    }
    private var isAgentRunning: Bool { chatState.runningProjectID != nil }
    private var runningProjectID: UUID? { chatState.runningProjectID }
    private var agentActivityState: EditorAgentActivityState { chatState.activity }
    private var agentActivityID: String? { chatState.activityID }
    @State private var playSession: MobileEditorPlaySession?
    @State private var presentedPlayProject: MobileEditorProject?
    @State private var providerModels = MobileEditorProviderModelStore()
    @State private var isModelPickerPresented = false
    @State private var presentedFile: MobileEditorFilePresentation?
    @State private var isPromptPresented = false

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
        .fullScreenCover(isPresented: $isPromptPresented, transition: .opacity) {
            MobileEditorPromptPanel(
                text: $promptDraft,
                attachmentNames: pendingPromptAttachments.map(\.lastPathComponent),
                isAgentRunning: isAgentRunning,
                pickFiles: pickAgentFiles,
                pickPhotos: pickAgentPhotos,
                submit: {
                    isPromptPresented = false
                    if let id = activeChatProjectID { submitPrompt(for: id) }
                }
            )
        }
        .fullScreenCover(item: $presentedPlayProject) { project in
            MobileEditorPlayScreen(
                project: project,
                runtimeSession: playSession?.projectID == project.id ? playSession?.runtime : nil,
                capture: playSession?.projectID == project.id ? playSession?.capture : nil,
                message: agentStatus,
                isAgentRunning: isAgentRunning,
                submitFeedback: { image, markup, text in
                    try await submitGameFeedback(image: image, markup: markup, text: text, for: project.id)
                }
            )
        }
        .fullScreenCover(isPresented: $isModelPickerPresented) {
            MobileEditorModelPickerScreen(modelStore: providerModels)
        }
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
                    pendingAttachmentNames: pendingPromptAttachments.map(\.lastPathComponent),
                    chatEvents: chatEvents,
                    agentStatus: agentStatus,
                    agentActivityState: agentActivityState,
                    agentActivityID: agentActivityID,
                    preparePlay: { preparePlay(for: id) },
                    onOpenFile: { relativePath in
                        presentedFile = MobileEditorFilePresentation(project: project, relativePath: relativePath)
                    },
                    openPrompt: { isPromptPresented = true }
                )
                .navigationTitle(project.title)
                .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
                .navigationTitlePosition(.center)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarColor(theme.editorColors.background)
                .navigationBarTrailingItems {
                    if !isPromptPresented {
                        Button {
                            navigationPath.append(MobileEditorDestination.projectSettings(id))
                        } label: {
                            Text("\u{E5D4}")
                                .foregroundColor(.white)
                                .frame(width: 40, height: 40)
                                .environment(\.font, AdaEditorMaterialSymbolFont.font(size: 25))
                        }
                        .accessibilityIdentifier("AdaEditor.Mobile.WorkspaceSettings")
                    }
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
            MobileEditorAgentSettingsScreen(modelStore: providerModels) {
                isModelPickerPresented = true
            }
                .navigationTitle("Providers")
                .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
                .navigationTitlePosition(.center)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarColor(theme.editorColors.background)
        case .projectSettings(let id):
            if let project = projects.first(where: { $0.id == id }) {
                MobileEditorProjectSettingsScreen(
                    project: project,
                    isBusy: runningProjectID == id,
                    rename: { title in
                        guard runningProjectID != id else { return }
                        projects = try MobileAdaScriptProjectService.renameProject(id: id, to: title)
                    },
                    delete: {
                        guard runningProjectID != id else { return }
                        projects = try MobileAdaScriptProjectService.deleteProject(id: id)
                        chatEvents = []
                        activeChatProjectID = nil
                        playSession?.capture.stop()
                        playSession = nil
                        navigationPath = NavigationPath()
                    },
                    showSessions: { navigationPath.append(MobileEditorDestination.sessions(id)) }
                )
                .navigationTitle("Project settings")
                .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarColor(theme.editorColors.background)
            }
        case .sessions(let id):
            if let directory = try? MobileAdaScriptProjectService.projectURL(for: id) {
                MobileEditorSessionsScreen(workspaceURL: directory) { sessionID in
                    navigationPath.append(MobileEditorDestination.session(id, sessionID))
                }
                .navigationTitle("Previous sessions")
                .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarColor(theme.editorColors.background)
            }
        case .session(let id, let sessionID):
            if let directory = try? MobileAdaScriptProjectService.projectURL(for: id) {
                MobileEditorSessionDetailScreen(workspaceURL: directory, sessionID: sessionID)
                    .navigationTitle("Conversation")
                    .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationBarColor(theme.editorColors.background)
            }
        }
    }

    private func createProject() {
        let project = MobileEditorProject(
            id: UUID(),
            title: "New Game \(projects.count)",
            prompt: nil
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
        withTransaction(Transaction()) {
            workspaceTab = .build
            promptDraft = ""
            pendingPromptAttachments = []
            chatState.open(project.id)
            playSession?.capture.stop()
            playSession = nil
            navigationPath.append(MobileEditorDestination.workspace(project.id))
            Task { @MainActor in await loadChat(for: project.id) }
        }
    }

    private func preparePlay(for id: UUID) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        do {
            let directory = try MobileAdaScriptProjectService.prepare(project)
            let artifact = try MobileAdaScriptProjectService.build(at: directory)
            let capture = EditorProjectPreviewCapture(projectURL: directory)
            let runtime = try EditorAdaScriptProjectRuntimeSession(artifact: artifact, previewCapture: capture)
            playSession?.capture.stop()
            withTransaction(Transaction()) {
                playSession = MobileEditorPlaySession(projectID: id, runtime: runtime, capture: capture)
                presentedPlayProject = project
            }
        } catch {
            playSession?.capture.stop()
            playSession = nil
            agentStatus = error.localizedDescription
        }
    }

    private func submitGameFeedback(image: Image, markup: EditorGameScreenshotMarkup, text: String, for id: UUID) async throws {
        guard !isAgentRunning, activeChatProjectID == id else { return }
        let data = try await markup.pngData(for: image)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("game-feedback-\(UUID().uuidString).png")
        try data.write(to: url, options: .atomic)
        promptDraft = text
        pendingPromptAttachments.append(url)
        workspaceTab = .build
        presentedPlayProject = nil
        submitPrompt(for: id)
    }

    private func submitPrompt(for id: UUID) {
        let value = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!value.isEmpty || !pendingPromptAttachments.isEmpty), !isAgentRunning,
              let index = projects.firstIndex(where: { $0.id == id }) else {
            return
        }
        let credentials = MobileSloppyCredentialStore.load()
        let codexCredentials = MobileCodexCredentialStore.load()
        let usesCodex = credentials?.provider.map { $0 == .codex } ?? (codexCredentials != nil)
        guard (usesCodex ? codexCredentials != nil : credentials?.apiKey.isEmpty == false),
              let credentials, !credentials.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            agentStatus = nil
            configureAgent()
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
        chatState.begin(id)
        let streamID = "stream-\(UUID().uuidString)"
        Task { @MainActor in
            do {
                if usesCodex, let codexCredentials {
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
                            guard !text.isEmpty else { return }
                            let event = EditorAgentEvent(
                                id: streamID,
                                kind: .message,
                                message: EditorAgentMessage(
                                    role: .assistant,
                                    segments: [EditorAgentMessageSegment(kind: .text, text: text)]
                                )
                            )
                            chatState.record(event, for: id)
                        }
                    },
                    onActivity: { activity in
                        await MainActor.run { MobileSloppyChatAdapter.record(activity, for: id, in: chatState) }
                    }
                )
                chatState.setStatus("Checking the AdaScript build…", for: id)
                _ = try MobileAdaScriptProjectService.build(at: workspaceURL)
                chatState.finish(id, succeeded: true, status: "AdaScript build succeeded")
            } catch {
                chatState.finish(id, succeeded: false, status: error.localizedDescription)
            }
            await loadChat(for: id)
        }
    }

    private func loadChat(for id: UUID) async {
        do {
            let directory = try MobileAdaScriptProjectService.projectURL(for: id)
            let events = try await MobileEditorSessionStore(workspaceURL: directory).events()
            chatState.load(events, for: id)
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
