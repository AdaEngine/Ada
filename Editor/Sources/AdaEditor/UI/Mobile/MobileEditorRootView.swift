#if os(iOS) || os(Android)
@_spi(AdaEngine) import AdaEngine
import Foundation
import Protocols
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SloppyRuntime)
import SloppyRuntime
#else
#error("Ada Studio Mobile requires the SloppyRuntimePortable package. Set SLOPPY_RUNTIME_LOCAL_PATH to its checkout.")
#endif

enum MobileEditorWorkspaceTab: Hashable {
    case build
    case files
    case play
}

private enum MobileEditorDestination: Hashable {
    case workspace(UUID)
    case settings
    case activity
    case agentSettings
    case providers
    case agentSkills
    case agentSkill(String)
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
    @Environment(\.navigationBarControlsAxis) private var navigationBarControlsAxis
    @State private var navigationPath: NavigationPath = NavigationPath()
    @State private var projects: [MobileEditorProject] = MobileAdaScriptProjectService.loadProjects()
    @State private var workspaceTab: MobileEditorWorkspaceTab = .build
    @State private var promptDraft = MobileEditorPromptDraft()
    @State private var pendingPromptAttachments: [URL] = []
    @State private var didPrepareImageQA = false
    @State private var didPrepareBackgroundQA = false
    @State private var didPrepareVoiceLayoutQA = false
    @State private var cloudAgent: EditorCloudAgentService?
    @State private var cloudPermission: EditorAgentPermissionRequest?
    @State private var cloudAdmitting = false
    @State private var sloppyRuntime = SloppyRuntimeHost()
    @State private var chatState = MobileEditorChatState()
    @State private var agentOperation: MobileEditorAgentOperation?
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
    @State private var harness = MobileAgentHarnessStore()
    @State private var isModelPickerPresented = false
    @State private var presentedFile: MobileEditorFilePresentation?
    @State private var isPromptPresented = false
    @State private var isVoicePresented = false
    @State private var publicationProject: MobileEditorProject?

    private let logo = ProjectOpeningAssets.loadAdaEngineLogo()

    private var navigationControlsLayout: AnyLayout {
        navigationBarControlsAxis == .vertical
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
    }

    var body: some View {
        MobileEditorHomeTabs(
            studio: studioNavigation,
            showsTabBar: navigationPath.isEmpty,
            server: URL(string: EditorCloudAccount.shared.server)
        )
        .mobileEditorSafeAreaContent(.bottom)
        .background(theme.editorColors.background.ignoresSafeArea())
        .overlay {
            if let permission = cloudPermission {
                MobileEditorCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.text("Allow project change?")).font(MobileEditorFont.navigationFont(size: 20)).foregroundColor(theme.editorColors.text)
                        Text(permission.summary).font(MobileEditorFont.font(size: 13)).foregroundColor(theme.editorColors.muted).lineLimit(4)
                        HStack(spacing: 12) {
                            MobileEditorPrimaryButton(title: "Allow once") { resolveCloudPermission("allow") }
                            MobileEditorPrimaryButton(title: "Reject") { resolveCloudPermission("deny") }
                        }
                    }.padding(17)
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .accessibilityIdentifier("AdaEditor.Mobile.CloudPermission")
            }
        }
        .onAppear {
            #if os(Android)
            AndroidStudioHost.refreshInsets()
            AndroidRuntime.backRequested = {
                if isPromptPresented { isPromptPresented = false }
                else if isVoicePresented { isVoicePresented = false }
                else if isModelPickerPresented { isModelPickerPresented = false }
                else if presentedFile != nil { presentedFile = nil }
                else if presentedPlayProject != nil { presentedPlayProject = nil }
                else if publicationProject != nil { publicationProject = nil }
                else if !navigationPath.isEmpty { navigationPath.removeLast() }
                else { return false }
                return true
            }
            #endif
            installMobileNotifications()
            #if DEBUG && targetEnvironment(simulator)
            if !didPrepareVoiceLayoutQA, CommandLine.arguments.contains("--mobile-voice-layout-qa"), let project = projects.first {
                didPrepareVoiceLayoutQA = true
                openProject(project)
                Task { @MainActor in
                    await Task.yield()
                    isVoicePresented = true
                }
            }
            if CommandLine.arguments.contains("--mobile-session-restart-qa") {
                do {
                    let project = try MobileEditorSessionRestartQA.prepare()
                    if !projects.contains(where: { $0.id == project.id }) {
                        projects.insert(project, at: 0)
                        try MobileAdaScriptProjectService.saveProjects(projects)
                    }
                } catch { agentStatus = error.localizedDescription }
            }
            prepareImagePasteQA()
            if !didPrepareBackgroundQA, CommandLine.arguments.contains("--mobile-background-agent-qa") {
                didPrepareBackgroundQA = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    MobileEditorBackgroundAgentQA.start()
                    navigationPath.append(MobileEditorDestination.activity)
                }
            }
            #endif
        }
        .fullScreenCover(isPresented: $isPromptPresented, transition: .opacity) {
            MobileEditorPromptPanel(
                text: promptDraft.binding,
                attachmentURLs: pendingPromptAttachments,
                removeAttachment: { url in pendingPromptAttachments.removeAll { $0 == url } },
                pasteImages: pasteAgentImages,
                isAgentRunning: isAgentRunning,
                pickFiles: pickAgentFiles,
                pickPhotos: pickAgentPhotos,
                submit: {
                    isPromptPresented = false
                    if let id = activeChatProjectID { submitPrompt(for: id) }
                },
                openVoice: {
                    isPromptPresented = false
                    Task { @MainActor in
                        await Task.yield()
                        isVoicePresented = true
                    }
                }
            )
            .mobileEditorSafeAreaContent()
        }
        .fullScreenCover(isPresented: $isVoicePresented, transition: .opacity) {
            MobileEditorVoicePanel(
                text: promptDraft.binding,
                events: chatEvents,
                isAgentRunning: isAgentRunning,
                agentStatus: agentStatus,
                agentActivity: agentActivityState,
                submit: {
                    guard let id = activeChatProjectID else { return false }
                    submitPrompt(for: id)
                    return isAgentRunning || cloudAdmitting
                },
                openKeyboard: {
                    isVoicePresented = false
                    Task { @MainActor in
                        await Task.yield()
                        isPromptPresented = true
                    }
                }
            )
            .mobileEditorSafeAreaContent()
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
                .mobileEditorSafeAreaContent()
        }
        .fullScreenCover(item: $publicationProject) { project in
            if let root = try? MobileAdaScriptProjectService.projectURL(for: project.id) {
                MobileEditorPublishScreen(projectURL: root, title: project.title, close: { publicationProject = nil })
                    .mobileEditorSafeAreaContent()
            }
        }
        .fullScreenCover(item: $presentedFile) { request in
            MobileEditorFileCover(project: request.project, relativePath: request.relativePath)
                .mobileEditorSafeAreaContent()
        }
    }

    private var studioNavigation: some View {
        NavigationStack(path: $navigationPath) {
            MobileEditorProjectsScreen(projects: projects, create: createProject, open: openProject)
                .overlay(anchor: .topTrailing) { creditsBadge.padding(.trailing, 16).padding(.top, 24) }
                .navigationTitle(L10n.text("Ada Studio"))
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
                    navigationControlsLayout {
                        Button { navigationPath.append(MobileEditorDestination.activity) } label: {
                            Text("\u{E7F4}")
                                .foregroundColor(theme.editorColors.text)
                                .frame(width: 40, height: 40)
                                .font(AdaEditorMaterialSymbolFont.font(size: 24))
                        }
                        .accessibilityIdentifier("AdaEditor.Mobile.ActivityButton")
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
                }
                .navigate(for: MobileEditorDestination.self, destination: destination)
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
                    promptDraft: promptDraft.binding,
                    isComposerPresented: isPromptPresented || isVoicePresented,
                    pendingAttachments: pendingPromptAttachments,
                    chatEvents: chatEvents,
                    sessionID: chatState.sessionID(for: id),
                    a2uiPresentation: mobileA2UIPresentation(for: project),
                    previousSession: chatState.previousSession,
                    resumePreviousSession: { Task { @MainActor in await resumePreviousSession(for: id) } },
                    agentStatus: chatState.interfaces.persistenceError ?? agentStatus,
                    agentActivityState: agentActivityState,
                    agentActivityID: agentActivityID,
                    preparePlay: { preparePlay(for: id) },
                    onOpenFile: { relativePath in
                        presentedFile = MobileEditorFilePresentation(project: project, relativePath: relativePath)
                    },
                    openPrompt: { isPromptPresented = true },
                    openVoice: { isVoicePresented = true },
                    embeddedRuntime: playSession?.projectID == id ? playSession?.runtime : nil,
                    prepareEmbeddedPlay: { preparePlay(for: id, presentsFullscreen: false) },
                    topAccessory: AnyView(creditsBadge),
                    inlineComposer: AnyView(MobileEditorInlineComposer(
                        text: promptDraft.binding, attachmentURLs: pendingPromptAttachments, isWorking: isAgentRunning,
                        removeAttachment: { url in pendingPromptAttachments.removeAll { $0 == url } },
                        pasteImages: pasteAgentImages, pickFiles: pickAgentFiles, pickPhotos: pickAgentPhotos,
                        submit: { submitPrompt(for: id) }, voice: { isVoicePresented = true }
                    ))
                )
                .navigationBarContentExtendsIntoSideControls()
                .navigationBarContentExtendsUnderNavigationBar()
                .navigationTitle(project.title)
                .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
                .navigationTitlePosition(.center)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarColor(theme.editorColors.background)
                .navigationBarTrailingItems {
                    navigationControlsLayout {
                        if navigationBarControlsAxis == .vertical {
                            creditsBadge
                        }
                        if runningProjectID == id, !isVoicePresented {
                            Button { agentOperation?.cancel() } label: {
                                Text("\u{E047}")
                                    .foregroundColor(theme.editorColors.text)
                                    .frame(width: 40, height: 40)
                                    .font(AdaEditorMaterialSymbolFont.font(size: 24))
                            }
                            .accessibilityIdentifier("AdaEditor.Mobile.StopAgent")
                        }
                        if !isPromptPresented, !isVoicePresented {
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
                        if navigationBarControlsAxis == .vertical, !isPromptPresented, !isVoicePresented {
                            Button { preparePlay(for: id) } label: {
                                Text("\u{E037}")
                                    .foregroundColor(theme.editorColors.text)
                                    .font(AdaEditorMaterialSymbolFont.font(size: 24))
                                    .frame(width: 40, height: 40)
                            }
                            .accessibilityIdentifier("AdaEditor.Mobile.WorkspacePlay")
                        }
                    }
                }
            } else {
                Text(L10n.text("Project unavailable"))
                    .navigationTitle(L10n.text("Project"))
                    .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
            }
        case .settings:
            MobileEditorSettingsScreen(agentStatus: agentStatus, configureAgent: configureAgent)
                .navigationTitle(L10n.text("Settings"))
                .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
                .navigationTitlePosition(.center)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarColor(theme.editorColors.background)
        case .activity:
            MobileEditorActivityScreen()
                .navigationTitle(L10n.text("Activity"))
                .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarColor(theme.editorColors.background)
        case .agentSettings:
            MobileEditorHarnessScreen(
                store: harness,
                isBusy: isAgentRunning,
                showProviders: { navigationPath.append(MobileEditorDestination.providers) },
                showSkills: { navigationPath.append(MobileEditorDestination.agentSkills) }
            )
                .navigationTitle(L10n.text("Agent"))
                .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
                .navigationTitlePosition(.center)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarColor(theme.editorColors.background)
        case .providers:
            MobileEditorAgentSettingsScreen(modelStore: providerModels) {
                isModelPickerPresented = true
            }
                .navigationTitle(L10n.text("Providers"))
                .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
                .navigationTitlePosition(.center)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarColor(theme.editorColors.background)
        case .agentSkills:
            MobileEditorSkillsScreen(store: harness, isBusy: isAgentRunning) {
                navigationPath.append(MobileEditorDestination.agentSkill($0))
            }
                .navigationTitle(L10n.text("Skills"))
                .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarColor(theme.editorColors.background)
        case .agentSkill(let id):
            if let skill = (MobileAgentHarnessSkill.builtIns + harness.settings.installedSkills).first(where: { $0.id == id }) {
                MobileEditorSkillDetailScreen(skill: skill)
                    .navigationTitle(skill.name)
                    .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationBarColor(theme.editorColors.background)
            }
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
                    showSessions: { navigationPath.append(MobileEditorDestination.sessions(id)) },
                    showPublication: { publicationProject = project }
                )
                .navigationTitle(L10n.text("Project settings"))
                .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarColor(theme.editorColors.background)
            }
        case .sessions(let id):
            if let directory = try? MobileAdaScriptProjectService.projectURL(for: id) {
                MobileEditorSessionsScreen(workspaceURL: directory, cloud: providerModels.selectedProvider == .ada) { sessionID in
                    navigationPath.append(MobileEditorDestination.session(id, sessionID))
                }
                .navigationTitle(L10n.text("Previous sessions"))
                .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarColor(theme.editorColors.background)
            }
        case .session(let id, let sessionID):
            if let directory = try? MobileAdaScriptProjectService.projectURL(for: id) {
                MobileEditorSessionDetailScreen(workspaceURL: directory, sessionID: sessionID)
                    .navigationTitle(L10n.text("Conversation"))
                    .navigationTitleFont(MobileEditorFont.navigationFont(size: 18))
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationBarColor(theme.editorColors.background)
            }
        }
    }

    private var creditsBadge: some View {
        EditorAICreditsBadge(compact: true, onOpen: {
            navigationPath.append(MobileEditorDestination.settings)
        })
    }

    private func createProject() {
        let project = MobileEditorProject(
            id: UUID(),
            title: L10n.text("New Game \(projects.count)"),
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
            promptDraft.text = ""
            pendingPromptAttachments = []
            chatState.open(project.id)
            playSession?.capture.stop()
            playSession = nil
            prepareMobileA2UI(for: project.id)
            Task { @MainActor in await findPreviousSession(for: project.id) }
        }
        withAnimation(.easeInOut(duration: 0.28)) {
            navigationPath.append(MobileEditorDestination.workspace(project.id))
        }
    }

    private func preparePlay(for id: UUID, presentsFullscreen: Bool = true) {
        if !presentsFullscreen, playSession?.projectID == id { return }
        guard let project = projects.first(where: { $0.id == id }) else { return }
        do {
            let directory = try MobileAdaScriptProjectService.prepare(project)
            let artifact = try MobileAdaScriptProjectService.build(at: directory)
            let capture = EditorProjectPreviewCapture(projectURL: directory)
            let runtime = try EditorAdaScriptProjectRuntimeSession(artifact: artifact, previewCapture: capture)
            playSession?.capture.stop()
            withTransaction(Transaction()) {
                playSession = MobileEditorPlaySession(projectID: id, runtime: runtime, capture: capture)
                if presentsFullscreen { presentedPlayProject = project }
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
        promptDraft.text = text
        pendingPromptAttachments.append(url)
        workspaceTab = .build
        presentedPlayProject = nil
        submitPrompt(for: id)
    }

    private func resolveCloudPermission(_ choice: String) {
        guard let permission = cloudPermission, let service = cloudAgent else { return }
        cloudPermission = nil
        Task { await service.resolvePermission(requestID: permission.id, optionID: choice) }
    }

    private func submitPrompt(for id: UUID, a2uiSubmission: EditorAgentA2UISubmission? = nil, cloudAdmitted: EditorCloudAIConnection? = nil) {
        var started = false, deferredAdmission = false
        defer {
            if !started, !deferredAdmission, let a2uiSubmission {
                chatState.interfaces.controller.sessions[a2uiSubmission.sessionID]?.rejectSubmission(
                    agentStatus ?? "The agent could not start. Check its connection settings.", surfaceID: a2uiSubmission.surfaceID)
            }
        }
        let value = a2uiSubmission?.summary ?? promptDraft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!value.isEmpty || !pendingPromptAttachments.isEmpty), !isAgentRunning,
              let index = projects.firstIndex(where: { $0.id == id }) else {
            return
        }
        let credentials = MobileSloppyCredentialStore.load() ?? MobileSloppyCredentials(model: MobileEditorProviderModelStore.cloudModel.id, provider: .ada)
        let codexCredentials = MobileCodexCredentialStore.load()
        let usesAda = credentials.provider == .ada
        let usesCodex = credentials.provider.map { $0 == .codex } ?? (codexCredentials != nil)
        guard (usesAda || (usesCodex ? codexCredentials != nil : !credentials.apiKey.isEmpty)),
              !credentials.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            agentStatus = nil
            configureAgent()
            return
        }
        if usesAda, cloudAdmitted == nil {
            guard !cloudAdmitting else { return }
            cloudAdmitting = true; deferredAdmission = true
            let draft = promptDraft.text
            let cloudOwner = EditorCloudAccount.shared.accountID, cloudServer = EditorCloudAccount.shared.server
            Task { @MainActor in
                var continued = false
                defer {
                    cloudAdmitting = false
                    if !continued, let a2uiSubmission {
                        chatState.interfaces.controller.sessions[a2uiSubmission.sessionID]?.rejectSubmission(
                            "The agent could not start. Check its connection settings.", surfaceID: a2uiSubmission.surfaceID)
                    }
                }
                do {
                    let transport = try await EditorCloudAccount.shared.hostedAIGenerator()
                    guard EditorCloudAccount.shared.accountID == cloudOwner, EditorCloudAccount.shared.server == cloudServer,
                          activeChatProjectID == id, !isAgentRunning,
                          a2uiSubmission != nil || promptDraft.text == draft,
                          (MobileSloppyCredentialStore.load()?.provider ?? .ada) == .ada else { return }
                    continued = true
                    submitPrompt(for: id, a2uiSubmission: a2uiSubmission, cloudAdmitted: transport)
                } catch {
                    guard providerModels.selectedProvider == .ada else { return }
                    agentStatus = L10n.tr(error.localizedDescription)
                    providerModels.reportCloudError(error.localizedDescription)
                    isVoicePresented = false
                    navigationPath.append(MobileEditorDestination.providers)
                }
            }
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
        let imageInputs: [SloppyImageInput]
        do {
            attachmentPaths = a2uiSubmission == nil ? try savePromptAttachments(into: workspaceURL) : []
            imageInputs = try attachmentPaths.compactMap { path in
                let url = workspaceURL.appendingPathComponent(path)
                guard EditorImageAttachment.extensions.contains(url.pathExtension.lowercased()) else { return nil }
                return SloppyImageInput(data: try EditorImageAttachment.pngData(at: url), relativePath: path)
            }
            try SloppyRuntimeHost.validateImages(imageInputs)
            if usesAda, !imageInputs.isEmpty {
                throw EditorAgentServiceError.providerFailure(L10n.text("Coder Next supports text. Choose a vision model to send images."))
            }
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
        chatState.selectProvider(cloud: usesAda, for: id)
        projects[index].prompt = value
        do {
            try MobileAdaScriptProjectService.saveProjects(projects)
        } catch {
            agentStatus = error.localizedDescription
            return
        }
        if a2uiSubmission == nil {
            promptDraft.text = ""
            pendingPromptAttachments = []
        }
        chatEvents.append(EditorAgentEvent(
            kind: .message,
            message: EditorAgentMessage(
                role: .user,
                segments: [EditorAgentMessageSegment(kind: .text, text: outgoingPrompt)]
            )
        ))
        prepareMobileA2UI(for: id)
        chatState.begin(id, agentIdentity: mobileAgentIdentity)
        let sessionID = chatState.sessionID(for: id)
        let runSettings = harness.settings
        let streamID = "stream-\(UUID().uuidString)"
        let operation = MobileEditorAgentOperation(projectID: id)
        agentOperation = operation
        started = true
        operation.start(
            projectName: projects[index].title,
            requestBackground: { activityID, coordinator in
                #if os(iOS)
                if #available(iOS 26.0, *) {
                    EditorContinuedProcessing.shared.request(for: activityID, coordinator: coordinator, onUnavailable: operation.backgroundUnavailable)
                } else {
                    coordinator.update(activityID, detail: "Connecting to the model…", backgroundStatus: "Background agent execution requires iOS/iPadOS 26.")
                    operation.backgroundUnavailable("Background agent execution requires iOS/iPadOS 26. Keep the app open for this request.")
                }
                #else
                coordinator.update(activityID, detail: "Connecting to the model…", backgroundStatus: "Keep Ada Studio open while the agent works.")
                #endif
            },
            work: {
                let toolService = EditorMobileAgentToolService(
                    projectURL: workspaceURL,
                    liveDiagnostics: { playSession?.projectID == id ? (playSession?.runtime.view.diagnostics ?? []) : [] },
                    startPlay: {
                        guard MobileEditorPlatform.isForeground else {
                            throw NSError(domain: "AdaEditor.MobilePlay", code: 2, userInfo: [NSLocalizedDescriptionKey: "Play rendering requires the foreground. Use editor.runtime tools in the background, then capture Play after reopening the app."])
                        }
                        preparePlay(for: id)
                        guard playSession?.projectID == id else {
                            throw NSError(domain: "AdaEditor.MobilePlay", code: 1, userInfo: [NSLocalizedDescriptionKey: agentStatus ?? "Play could not start."])
                        }
                    },
                    imageCredentials: MobileEditorImageCredentials(),
                    imageAnalyzer: { urls, question in
                        let images = try urls.map { SloppyImageInput(data: try EditorImageAttachment.pngData(at: $0)) }
                        return try await sloppyRuntime.analyzeImages(images, question: question)
                    },
                    capturePlay: {
                        try Task.checkCancellation()
                        guard MobileEditorPlatform.isForeground else {
                            throw NSError(domain: "AdaEditor.MobilePlay", code: 2, userInfo: [NSLocalizedDescriptionKey: "Play capture requires the foreground. Use editor.runtime tools while the app is in the background."])
                        }
                        guard playSession?.projectID == id, let capture = playSession?.capture else {
                            throw CocoaError(.featureUnsupported)
                        }
                        let image = try await capture.nextFrame()
                        return try EditorImageAttachment.encodePNG(image)
                    },
                    harnessSettings: runSettings
                )
                defer { toolService.finish() }
                if usesAda {
                    let service = EditorCloudAgentService(
                        host: .mobile,
                        connectionFactory: {
                            guard let cloudAdmitted else { throw EditorAIError.sessionChanged }
                            return cloudAdmitted
                        },
                        toolsFactory: { url in
                            try await MainActor.run { try EditorCloudToolHost(projectURL: url, mobile: toolService).tools() }
                        }
                    )
                    cloudAgent = service
                    let project = try ProjectSystem.loadProject(at: workspaceURL)
                    let request = EditorAgentRunRequest(project: project, projectURL: workspaceURL,
                        session: .init(id: sessionID, events: chatState.events(for: id)), mode: .build,
                        prompt: MobileEditorAgentContext.prompt(runSettings.prompt(outgoingPrompt), visiblePrompt: outgoingPrompt, a2uiAction: a2uiSubmission?.event),
                        attachments: [], sceneContext: nil, codeSelection: nil, skills: [], a2uiEnabled: true)
                    _ = try await service.send(request, onEvent: { event in
                        await MainActor.run {
                            chatState.record(event, for: id)
                            if let permission = event.permission {
                                isVoicePresented = false; isPromptPresented = false
                                cloudPermission = permission
                            }
                            if event.kind == .toolCall { operation.completedStep() }
                        }
                    }, onProjectFileChanged: { _ in })
                    try Task.checkCancellation()
                    let validation = await toolService.validatePrototype()
                    return .init(succeeded: validation.ok, detail: validation.ok ? "Done" : validation.payload)
                }
                sloppyRuntime = SloppyRuntimeHost(additionalTools: try MobileEditorAgentToolBridge.definitions())
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
                operation.completedStep()
                var turnPrompt = MobileEditorAgentContext.prompt(
                    runSettings.prompt(outgoingPrompt), visiblePrompt: outgoingPrompt, a2uiAction: a2uiSubmission?.event
                )
                for attempt in 0...runSettings.repairAttempts {
                    try Task.checkCancellation()
                    let responseStreamID = attempt == 0 ? streamID : "repair-\(UUID().uuidString)"
                    _ = try await sloppyRuntime.send(
                        prompt: turnPrompt,
                        sessionID: sessionID,
                        workspaceURL: workspaceURL,
                        build: {
                            await MainActor.run {
                                guard !Task.isCancelled else { return SloppyBuildResult(ok: false, summary: "Agent stopped.") }
                                let result = toolService.build()
                                return SloppyBuildResult(ok: result.ok, summary: result.payload)
                            }
                        },
                        onText: { text in
                            await MainActor.run {
                                guard !Task.isCancelled, !text.isEmpty else { return }
                                operation.update("Writing the response…")
                                let event = EditorAgentEvent(
                                    id: responseStreamID,
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
                            await MainActor.run {
                                guard !Task.isCancelled else { return }
                                MobileSloppyChatAdapter.record(activity, for: id, in: chatState)
                                switch activity {
                                case .thinking: operation.update("Thinking…")
                                case .toolStarted(let tool): operation.update("Using \(tool)…")
                                case .toolFinished(let tool, let succeeded):
                                    if !succeeded { operation.failedTool(tool) }
                                    operation.completedStep()
                                    operation.update("Agent is working…")
                                }
                            }
                        },
                        additionalToolHandler: { request in
                            guard !Task.isCancelled else {
                                return ToolInvocationResult(tool: request.tool, ok: false, error: ToolErrorPayload(code: "cancelled", message: "Agent stopped.", retryable: false))
                            }
                            let result = await MobileEditorAgentToolBridge.invoke(request, service: toolService)
                            if !result.ok, let error = result.error {
                                await MainActor.run { operation.reportError(error.message, tool: request.tool) }
                            }
                            return result
                        },
                        maxToolRounds: runSettings.maxToolRounds,
                        images: attempt == 0 ? imageInputs : [],
                        persistedSessionID: sessionID
                    )
                    try Task.checkCancellation()
                    operation.completedStep()
                    operation.update("Checking AdaScript and project scenes…")
                    chatState.setStatus("Checking AdaScript and project scenes…", for: id)
                    let validation = await toolService.validatePrototype()
                    try Task.checkCancellation()
                    operation.completedStep()
                    if validation.ok {
                        let hasChatUI = chatState.interfaces.controller.sessions[sessionID]?.didPresentUIInCurrentRun == true
                        if runSettings.opensPreview, !hasChatUI, MobileEditorPlatform.isForeground { preparePlay(for: id) }
                        return .init(succeeded: true, detail: "AdaScript, scenes and simulation validated")
                    }
                    operation.reportError(validation.payload)
                    if attempt == runSettings.repairAttempts {
                        return .init(succeeded: false, detail: validation.payload)
                    }
                    operation.update("Repairing build errors…")
                    chatState.setStatus("Repairing build errors…", for: id)
                    let repairPrompt = """
                    [Automatic validation feedback]
                    The final project validation failed. Fix the errors with the available editor tools, then rebuild.
                    Do not repeat the previous completion claim. Read editor.output.read, diagnostics and the relevant documentation.
                    \(validation.payload)
                    """
                    turnPrompt = MobileEditorAgentContext.prompt(runSettings.prompt(repairPrompt), visiblePrompt: "")
                }
                return .init(succeeded: false, detail: "The agent could not validate the project.")
            },
            finished: { state, detail in
                chatState.finish(id, succeeded: state == .completed, status: detail, cancelled: state == .cancelled || state == .interrupted, submission: a2uiSubmission)
                if usesAda {
                    cloudPermission = nil; cloudAgent = nil
                    do {
                        var session = EditorAgentSession(id: sessionID, title: String(value.prefix(80)), events: chatState.events(for: id))
                        session.agentTargetIdentity = mobileAgentIdentity
                        try await EditorAgentSessionStore(projectURL: workspaceURL).saveSession(session, makeActive: true)
                    } catch { agentStatus = error.localizedDescription }
                } else { await loadChat(for: id, sessionID: sessionID) }
                if state != .completed, chatState.sessionID(for: id) == sessionID {
                    chatState.record(EditorAgentEvent(kind: .runStatus, title: detail, isSuccessful: false), for: id)
                }
            }
        )
    }

    private var mobileAgentIdentity: String? {
        let credentials = MobileSloppyCredentialStore.load() ?? MobileSloppyCredentials(model: MobileEditorProviderModelStore.cloudModel.id, provider: .ada)
        if credentials.provider == .ada { return "ada-cloud:" + EditorCloudAccount.shared.server + ":" + (EditorCloudAccount.shared.accountID ?? "signedout") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(credentials) else { return nil }
        let account = MobileCodexCredentialStore.load()?.accountID ?? ""
        return EditorAgentSceneToolService.revision(for: String(decoding: data, as: UTF8.self) + account)
    }

    private func prepareMobileA2UI(for id: UUID) {
        do {
            let root = try MobileAdaScriptProjectService.projectURL(for: id)
            let ui = chatState.interfaces.prepare(sessionID: chatState.sessionID(for: id), projectURL: root,
                events: chatState.events(for: id), identity: mobileAgentIdentity)
            ui.onSubmission = { [weak ui] submission in
                guard let ui else { return }
                guard activeChatProjectID == id, !isAgentRunning, submission.sessionID == chatState.sessionID(for: id),
                      submission.agentIdentity == mobileAgentIdentity else {
                    ui.rejectSubmission("Reconnect the original agent and project before submitting.", surfaceID: submission.surfaceID)
                    return
                }
                if !chatState.interfaces.performLocal(submission) { submitPrompt(for: id, a2uiSubmission: submission) }
            }
        } catch { agentStatus = error.localizedDescription }
    }

    private func mobileA2UIPresentation(for project: MobileEditorProject) -> EditorAgentA2UIPresentation? {
        let id = chatState.sessionID(for: project.id)
        guard let ui = chatState.interfaces.controller.sessions[id] else { return nil }
        return .init(session: ui, isEnabled: !isAgentRunning, agentIdentity: mobileAgentIdentity,
            onOpenPreview: { surfaceID in
                do {
                    let path = try chatState.interfaces.export(surfaceID: surfaceID, sessionID: id)
                    presentedFile = MobileEditorFilePresentation(project: project, relativePath: path)
                } catch { ui.setError(error.localizedDescription, surfaceID: surfaceID) }
            },
            onUndo: { surfaceID in
                guard !isAgentRunning, ui.records[surfaceID]?.agentIdentity == mobileAgentIdentity else { return }
                chatState.interfaces.undo(surfaceID: surfaceID, sessionID: id)
            })
    }

    private func installMobileNotifications() {
        let center = EditorNotificationCenter.shared
        #if os(iOS)
        EditorSystemNotifications.shared.install(on: center)
        #endif
        center.onAction = { action in
            guard let projectID = action.projectID.flatMap(UUID.init(uuidString:)),
                  let project = projects.first(where: { $0.id == projectID }) else {
                EditorNotificationRouter.shared.receive(action)
                return
            }
            presentedFile = nil
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad { MobileEditorWindowLauncher.open() }
            #endif
            presentedPlayProject = nil
            isPromptPresented = false
            isVoicePresented = false
            navigationPath = NavigationPath()
            workspaceTab = .build
            openProject(project)
        }
        Task { await center.start() }
    }

    private func findPreviousSession(for id: UUID) async {
        guard chatState.needsPreviousSession(for: id) else { return }
        let sessionID = chatState.sessionID(for: id)
        do {
            let directory = try MobileAdaScriptProjectService.projectURL(for: id)
            let previous = try await MobileEditorSessionStore(workspaceURL: directory).list()
                .first { $0.id != sessionID && $0.messageCount > 0 && $0.id.hasPrefix("cloud-") == (providerModels.selectedProvider == .ada) }
            chatState.setPreviousSession(previous.map { .init(id: $0.id, title: $0.title) }, for: id, sessionID: sessionID)
        } catch {
            if activeChatProjectID == id { agentStatus = error.localizedDescription }
        }
    }

    private func resumePreviousSession(for id: UUID) async {
        guard runningProjectID != id, activeChatProjectID == id,
              let previous = chatState.previousSession else { return }
        let sessionID = chatState.sessionID(for: id)
        do {
            let directory = try MobileAdaScriptProjectService.projectURL(for: id)
            let events = try await MobileEditorSessionStore(workspaceURL: directory).events(id: previous.id)
            guard activeChatProjectID == id,
                  chatState.resumePreviousSession(for: id, expectedSessionID: sessionID, events: events) else { return }
            prepareMobileA2UI(for: id)
            promptDraft.text = ""
            pendingPromptAttachments = []
            workspaceTab = .build
        } catch {
            if activeChatProjectID == id { agentStatus = error.localizedDescription }
        }
    }

    private func loadChat(for id: UUID, sessionID: String) async {
        do {
            let directory = try MobileAdaScriptProjectService.projectURL(for: id)
            let events = try await MobileEditorSessionStore(workspaceURL: directory).events(id: sessionID)
            chatState.load(events, for: id, sessionID: sessionID)
        } catch {
            if activeChatProjectID == id {
                agentStatus = error.localizedDescription
            }
        }
    }

    private func configureAgent() {
        isVoicePresented = false
        navigationPath.append(MobileEditorDestination.agentSettings)
    }

    #if DEBUG && targetEnvironment(simulator)
    private func prepareImagePasteQA() {
        let codeQA = CommandLine.arguments.contains("--mobile-code-touch-qa")
        guard !didPrepareImageQA, codeQA || CommandLine.arguments.contains("--mobile-image-paste-qa") else { return }
        didPrepareImageQA = true
        do {
            let project = MobileEditorProject(id: UUID(), title: codeQA ? "Code Touch QA" : "Image Paste QA", prompt: nil)
            let directory = try MobileAdaScriptProjectService.prepare(project)
            projects.insert(project, at: 0)
            if codeQA {
                let source = (0..<200).map { "// Line \($0): swipe to scroll; long press then drag to select." }.joined(separator: "\n")
                try source.write(to: directory.appendingPathComponent("Sources/Game.ada"), atomically: true, encoding: .utf8)
            } else {
                try MobileEditorImagePaste.seedPreviewQA()
            }
            openProject(project)
            Task { @MainActor in
                await Task.yield()
                if codeQA {
                    presentedFile = MobileEditorFilePresentation(project: project, relativePath: "Sources/Game.ada")
                } else {
                    isPromptPresented = true
                }
            }
        } catch { agentStatus = error.localizedDescription }
    }
    #endif

    private func pasteAgentImages() -> Bool {
        do {
            let urls = try MobileEditorImagePaste.files()
            guard !urls.isEmpty else { return false }
            pendingPromptAttachments.append(contentsOf: urls)
            return true
        } catch {
            agentStatus = error.localizedDescription
            return true
        }
    }

    private func pickAgentFiles() {
        MobileEditorPlatform.pickFiles { result in
            handleAgentAttachmentPickerResult(result)
        }
    }

    private func pickAgentPhotos() {
        MobileEditorPlatform.pickPhotos { result in
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
