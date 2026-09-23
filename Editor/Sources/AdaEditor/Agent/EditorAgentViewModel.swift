@_spi(AdaEngine) import AdaEngine
import Foundation
import Observation

@Observable
@MainActor
final class EditorAgentViewModel {
    var connectionState: EditorAgentConnectionState = .disconnected
    var sessions: [EditorAgentSessionSummary] = []
    var activeSession: EditorAgentSession?
    var prompt: String = ""
    var mode: EditorAgentChatMode = .build
    var autocompleteSuggestions: [EditorAgentCompletion] = []
    var selectedCompletionIndex = 0
    var promptCompletionFocus: TextEditorSourceRange?
    @ObservationIgnored private var promptCaretOffset: Int?
    var pendingAttachments: [EditorAgentAttachment] = []
    var sceneContext: EditorAgentSceneContext?
    var codeSelection: EditorAgentCodeSelectionContext?
    var sessionConfiguration = EditorAgentSessionConfiguration.empty
    private var connectionSettings = AdaProjectAgent()
    var currentSessionConfiguration: EditorAgentSessionConfiguration {
        connectionSettings == settings.configuration ? sessionConfiguration : .empty
    }
    var currentConnectionState: EditorAgentConnectionState {
        connectionSettings == settings.configuration ? connectionState : .disconnected
    }
    var availableSkills: [EditorAgentSkill] = []
    var selectedSkillIDs: Set<String> = []
    var statusMessage: String?
    var isSending = false
    private(set) var lastActivityID: String?
    @ObservationIgnored private var notificationSessionID: String?
    @ObservationIgnored private var runningSession: EditorAgentSession?
    @ObservationIgnored private var runningActivityID: String?
    @ObservationIgnored private var permissionActivityIDs: [String: String] = [:]
    @ObservationIgnored let notifications: EditorNotificationCenter
    var agentEnabled: Bool {
        get { settings.agentEnabled }
        set { settings.agentEnabled = newValue }
    }
    var agentCommand: String {
        get { settings.agentCommand }
        set { settings.agentCommand = newValue }
    }
    var agentArguments: String {
        get { settings.agentArguments }
        set { settings.agentArguments = newValue }
    }
    var agentWorkingDirectory: String {
        get { settings.agentWorkingDirectory }
        set { settings.agentWorkingDirectory = newValue }
    }
    var agentEnvironment: String {
        get { settings.agentEnvironment }
        set { settings.agentEnvironment = newValue }
    }
    var agentSkillsDirectories: [String] {
        get { settings.agentSkillsDirectories }
        set { settings.agentSkillsDirectories = newValue }
    }
    var agentPermissionMode: AdaProjectAgentPermissionMode {
        get { settings.agentPermissionMode }
        set { settings.agentPermissionMode = newValue }
    }
    var settingsStatusMessage = ""
    let catalog: EditorAgentCatalogViewModel
    var isConnectingCatalogAgent = false

    @ObservationIgnored
    private let project: EditorProjectReference?
    @ObservationIgnored
    private let service: any EditorAgentServicing
    @ObservationIgnored
    private var store: EditorAgentSessionStore?
    @ObservationIgnored
    private var baseProjectConfig: AdaProject?
    let settings: EditorAgentSettingsStore
    private var projectConfig: AdaProject? {
        guard var project = baseProjectConfig else {
            return nil
        }
        project.ai.agent = settings.configuration
        return project
    }
    @ObservationIgnored
    private let fileManager: FileManager
    @ObservationIgnored
    private var onProjectFileChanged: (String) -> Void

    init(
        project: EditorProjectReference?,
        settings: EditorAgentSettingsStore = .shared,
        fileManager: FileManager = .default,
        service: any EditorAgentServicing = EditorACPAgentService(),
        catalog: EditorAgentCatalogViewModel = EditorAgentCatalogViewModel(),
        notifications: EditorNotificationCenter = .shared,
        onProjectFileChanged: @escaping (String) -> Void = { _ in }
    ) {
        self.settings = settings
        self.notifications = notifications
        self.project = project
        self.fileManager = fileManager
        self.service = service
        self.catalog = catalog
        catalog.notificationAction.projectID = project?.id
        catalog.notificationProjectName = project?.name
        self.onProjectFileChanged = onProjectFileChanged
        configureForProject()
        connectionSettings = settings.configuration
        if let error = settings.loadError {
            settingsStatusMessage = error
        }
    }

    func setProjectFileChangedHandler(_ handler: @escaping (String) -> Void) {
        onProjectFileChanged = handler
    }

    func setSceneContext(_ context: EditorAgentSceneContext?) {
        sceneContext = context
    }

    func prefillCodeSelection(_ context: EditorAgentCodeSelectionContext) {
        codeSelection = context
        prompt = """
            Help me with this selected code from \(context.documentRelativePath) (\(context.lineDescription)):

            ```\(context.language)
            \(context.text)
            ```
            """
        updateAutocomplete()
    }

    var promptBinding: Binding<String> {
        Binding(
            get: { self.prompt },
            set: { newValue in
                self.prompt = newValue
                self.promptCaretOffset = newValue.count
                self.promptCompletionFocus = nil
                self.updateAutocomplete()
            }
        )
    }

    var agentCommandBinding: Binding<String> {
        Binding(get: { self.agentCommand }, set: { self.agentCommand = $0 })
    }

    var agentArgumentsBinding: Binding<String> {
        Binding(get: { self.agentArguments }, set: { self.agentArguments = $0 })
    }

    var agentWorkingDirectoryBinding: Binding<String> {
        Binding(get: { self.agentWorkingDirectory }, set: { self.agentWorkingDirectory = $0 })
    }

    var agentEnvironmentBinding: Binding<String> {
        Binding(get: { self.agentEnvironment }, set: { self.agentEnvironment = $0 })
    }

    func skillDirectoryBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                self.agentSkillsDirectories.indices.contains(index) ? self.agentSkillsDirectories[index] : ""
            },
            set: { value in
                guard self.agentSkillsDirectories.indices.contains(index) else {
                    return
                }
                self.agentSkillsDirectories[index] = value
            }
        )
    }

    var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending && !isConnectingCatalogAgent
    }

    var selectedSkills: [EditorAgentSkill] {
        availableSkills.filter { selectedSkillIDs.contains($0.id) }
    }

    var projectURL: URL? {
        project.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    var projectName: String {
        project?.name ?? "Ada Agent"
    }

    func configureForProject() {
        guard let projectURL else {
            statusMessage = "No project is open."
            return
        }

        store = EditorAgentSessionStore(projectURL: projectURL)
        do {
            baseProjectConfig = try ProjectSystem.loadProject(at: projectURL, fileManager: fileManager)
        } catch {
            baseProjectConfig = ProjectSystem.defaultProject(projectName: project?.name ?? "Project")
            statusMessage = "Using default agent configuration."
        }

        if let legacy = baseProjectConfig?.ai.agent {
            do { try settings.migrateIfNeeded(legacy) } catch { settingsStatusMessage = error.localizedDescription }
        }
        if let projectConfig {
            availableSkills = EditorAgentSkillStore.discoverSkills(
                projectURL: projectURL,
                directories: projectConfig.ai.agent.skillsDirectories,
                fileManager: fileManager
            )
            connectionState = .disconnected
        }

        Task {
            await loadSessions()
        }
    }

    func loadSessions() async {
        guard let store else {
            return
        }

        do {
            sessions = try await store.listSessions()
            if let notificationSessionID {
                activeSession = runningSession?.id == notificationSessionID ? runningSession : try await store.loadSession(id: notificationSessionID)
                connectIfNeeded()
                return
            }
            if let activeID = try await store.activeSessionID(), let session = try? await store.loadSession(id: activeID) {
                activeSession = session
                selectedSkillIDs = Set(session.selectedSkillIDs)
                connectIfNeeded()
            } else if let first = sessions.first, let session = try? await store.loadSession(id: first.id) {
                activeSession = session
                selectedSkillIDs = Set(session.selectedSkillIDs)
                try await store.setActiveSession(id: first.id)
                connectIfNeeded()
            } else {
                try await createSession()
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func createSession(connectAutomatically: Bool = true) async throws {
        notificationSessionID = nil
        guard let store else {
            return
        }
        let session = try await store.createSession()
        activeSession = session
        sessions = try await store.listSessions()
        selectedSkillIDs = []
        prompt = ""
        pendingAttachments = []
        codeSelection = nil
        sessionConfiguration = .empty
        connectionState = .disconnected
        if connectAutomatically {
            connectIfNeeded()
        }
    }

    func selectSession(_ summary: EditorAgentSessionSummary) {
        notificationSessionID = nil
        guard let store else {
            return
        }
        Task {
            do {
                activeSession = runningSession?.id == summary.id ? runningSession : try await store.loadSession(id: summary.id)
                selectedSkillIDs = Set(activeSession?.selectedSkillIDs ?? [])
                if runningSession?.id != id {
                    sessionConfiguration = .empty
                    connectionState = .disconnected
                }
                try await store.setActiveSession(id: summary.id)
                connectIfNeeded()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func deleteSession(_ summary: EditorAgentSessionSummary) {
        guard runningSession?.id != summary.id else {
            statusMessage = "Stop the running agent before deleting its session."
            return
        }
        guard let store else {
            return
        }
        Task {
            do {
                await service.cancel(sessionID: summary.id)
                try await store.deleteSession(id: summary.id)
                sessions = try await store.listSessions()
                if activeSession?.id == summary.id {
                    if let next = sessions.first {
                        activeSession = try await store.loadSession(id: next.id)
                        selectedSkillIDs = Set(activeSession?.selectedSkillIDs ?? [])
                        sessionConfiguration = .empty
                        connectionState = .disconnected
                        try await store.setActiveSession(id: next.id)
                        connectIfNeeded()
                    } else {
                        try await createSession()
                    }
                }
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func sendPrompt() {
        guard canSend else {
            return
        }
        Task {
            await sendPromptAsync()
        }
    }

    func connect() {
        guard currentConnectionState != .connecting, !isConnectingCatalogAgent else {
            return
        }
        connectionState = .connecting
        Task {
            await connectAsync()
        }
    }

    func connectIfNeeded() {
        guard settings.configuration.enabled, activeSession != nil, currentConnectionState == .disconnected else {
            return
        }
        connect()
    }

    func selectConfiguration(selectorID: String, valueID: String) {
        guard connectionSettings == settings.configuration else {
            connect()
            return
        }
        guard let activeSession else {
            return
        }
        Task {
            do {
                sessionConfiguration = try await service.setConfiguration(
                    sessionID: activeSession.id,
                    selectorID: selectorID,
                    valueID: valueID
                )
                if let chatMode = EditorAgentChatMode(rawValue: valueID) {
                    mode = chatMode
                }
                connectionState = .ready(sessionConfiguration.agentName)
            } catch {
                statusMessage = error.localizedDescription
                connectionState = .failed(error.localizedDescription)
            }
        }
    }

    @discardableResult
    func useCatalogAgent(_ entry: EditorInstalledAgent) async -> Bool {
        guard !isSending else {
            settingsStatusMessage = "Stop the running agent before changing its settings."
            return false
        }
        do {
            var configuration = settings.configuration
            configuration.enabled = true
            configuration.target = entry.target
            try settings.save(configuration)
            await service.shutdown()
            // ACP session IDs belong to one provider; never resume them in another agent.
            try await createSession(connectAutomatically: false)
            connectionState = .disconnected
            settingsStatusMessage = "\(entry.name) selected for all projects. Open Agent Chat to send a message."
            return true
        } catch {
            settingsStatusMessage = "Unable to use \(entry.name): \(error.localizedDescription)"
            return false
        }
    }

    var canConnectCatalogAgent: Bool {
        !isSending && !isConnectingCatalogAgent && !catalog.isBusy && connectionState != .connecting
    }

    func isCatalogAgentSelected(_ entry: EditorInstalledAgent) -> Bool {
        settings.configuration.enabled && settings.configuration.target == entry.target
    }

    func connectCatalogAgent(
        installed: EditorInstalledAgent? = nil,
        local: EditorDiscoveredAgent? = nil,
        registry: EditorRegistryAgent? = nil
    ) async {
        guard canConnectCatalogAgent else {
            return
        }
        isConnectingCatalogAgent = true
        defer { isConnectingCatalogAgent = false }
        settingsStatusMessage = ""
        #if os(macOS)
            let target = installed?.target ?? local?.target
            if EditorSloppyLocalSetup.isSloppyTarget(target) {
                do {
                    guard try EditorSloppyLocalSetup.prepare() else { return }
                } catch {
                    settingsStatusMessage = "Unable to prepare Sloppy: \(error.localizedDescription)"
                    return
                }
            }
        #endif
        let entry: EditorInstalledAgent?
        if let installed {
            entry = installed
        } else if let local, local.target != nil {
            entry = await catalog.add(local)
        } else if let registry = registry ?? local.flatMap({ catalog.adapter(for: $0) }) {
            entry = await catalog.install(registry)
        } else {
            settingsStatusMessage = "ACP adapter unavailable. Refresh the registry or configure an ACP command below."
            return
        }
        guard let entry else {
            return
        }
        guard await useCatalogAgent(entry) else {
            return
        }
        guard projectURL != nil else {
            return
        }
        settingsStatusMessage = "Connecting to \(entry.name)…"
        await connectAsync()
        switch connectionState {
        case .ready:
            settingsStatusMessage = "\(entry.name) connected. Open Agent Chat to send a message."
        case let .failed(message):
            settingsStatusMessage = "\(entry.name) selected, but connection failed: \(message)"
        default:
            settingsStatusMessage = statusMessage ?? "Connection did not complete. Open Agent Chat to retry."
        }
    }

    func toggleAgentEnabled() {
        agentEnabled.toggle()
    }

    func selectPermissionMode(_ mode: AdaProjectAgentPermissionMode) {
        agentPermissionMode = mode
    }

    func saveAgentSettings() {
        guard !isSending else {
            settingsStatusMessage = "Stop the running agent before changing its settings."
            return
        }
        do {
            let oldTarget = settings.configuration.target
            let arguments =
                agentArguments == oldTarget.arguments.joined(separator: "\n")
                ? oldTarget.arguments : Self.lineList(from: agentArguments)
            let oldEnvironment = oldTarget.environment.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            let environment =
                agentEnvironment == oldEnvironment
                ? oldTarget.environment : Self.environment(from: agentEnvironment)
            let configuration = AdaProjectAgent(
                enabled: agentEnabled,
                target: AdaProjectAgentTarget(
                    command: agentCommand.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    arguments: arguments,
                    environment: environment,
                    cwd: agentWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ),
                permissionMode: agentPermissionMode,
                skillsDirectories: agentSkillsDirectories.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            )

            try settings.save(configuration)
            refreshSkills()
            settingsStatusMessage = "Agent settings saved for all projects."
            sessionConfiguration = .empty
            connectionState = .disconnected
        } catch {
            settingsStatusMessage = "Failed to save agent settings: \(error.localizedDescription)"
        }
    }

    func interrupt() {
        if let id = runningActivityID {
            notifications.activities.cancel(id)
        }
    }

    func openNotificationSession(_ id: String) {
        notificationSessionID = id
        Task {
            do {
                guard let store else {
                    return
                }
                activeSession = runningSession?.id == id ? runningSession : try await store.loadSession(id: id)
                selectedSkillIDs = Set(activeSession?.selectedSkillIDs ?? [])
                sessionConfiguration = .empty
                connectionState = .disconnected
                try await store.setActiveSession(id: id)
                connectIfNeeded()
            } catch {
                notificationSessionID = nil
                statusMessage = "This agent session is no longer available."
                notifications.post(
                    .init(
                        source: .agent,
                        importance: .warning,
                        title: "Session unavailable",
                        detail: "The session may have been deleted.",
                        projectName: project?.name,
                        requestsSystemDelivery: false
                    )
                )
            }
        }
    }

    func toggleSkill(_ skill: EditorAgentSkill) {
        if selectedSkillIDs.contains(skill.id) {
            selectedSkillIDs.remove(skill.id)
        } else {
            selectedSkillIDs.insert(skill.id)
        }
        activeSession?.selectedSkillIDs = Array(selectedSkillIDs).sorted()
        Task {
            await saveActiveSession()
        }
    }

    func attachFile(at url: URL) {
        guard let projectURL else {
            return
        }
        let attachment = EditorAgentAttachmentContext.attachment(forFileAt: url, projectURL: projectURL, fileManager: fileManager)
        guard pendingAttachments.contains(where: { $0.absolutePath == attachment.absolutePath }) == false else {
            return
        }
        pendingAttachments.append(attachment)
    }

    func removeAttachment(id: String) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func contextFiles(matching query: String, limit: Int = 40) -> [EditorAgentProjectFileSearch.Entry] {
        guard let projectURL else {
            return []
        }
        return
            EditorAgentProjectFileSearch.search(
                projectURL: projectURL,
                query: query,
                limit: limit,
                fileManager: fileManager
            )
            .filter { !$0.isDirectory }
    }

    func attachProjectFile(_ entry: EditorAgentProjectFileSearch.Entry) {
        guard let projectURL, !entry.isDirectory else {
            return
        }
        attachFile(at: projectURL.appendingPathComponent(entry.path, isDirectory: false))
    }

    func presentContextFilePicker() {
        ProjectOpenPicker.presentAgentContextPicker { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case let .selected(urls):
                for url in urls {
                    self.attachFile(at: url)
                }
            case .cancelled:
                break
            case let .unavailable(message):
                self.statusMessage = message
            }
        }
    }

    func resolvePermission(requestID: String, optionID: String?) {
        if let id = permissionActivityIDs.removeValue(forKey: requestID), !permissionActivityIDs.values.contains(id) {
            notifications.activities.resume(id)
        }
        Task {
            await service.resolvePermission(requestID: requestID, optionID: optionID)
        }
    }

    func updatePromptCaret(_ position: TextEditorSourcePosition, text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let line = min(max(position.line, 0), max(0, lines.count - 1))
        promptCaretOffset =
            lines.prefix(line).reduce(0) { $0 + $1.count + 1 }
            + min(max(position.column, 0), lines[line].count)
        updateAutocomplete()
    }

    func moveCompletionSelection(_ delta: Int) -> Bool {
        guard !autocompleteSuggestions.isEmpty else {
            return false
        }
        selectedCompletionIndex = (selectedCompletionIndex + delta + autocompleteSuggestions.count) % autocompleteSuggestions.count
        return true
    }

    func submitPromptFromKeyboard() -> Bool {
        if acceptCompletion() {
            return true
        }
        if canSend {
            sendPrompt()
        }
        return true
    }

    func acceptCompletion() -> Bool {
        guard autocompleteSuggestions.indices.contains(selectedCompletionIndex) else {
            return false
        }
        insertAutocomplete(autocompleteSuggestions[selectedCompletionIndex])
        return true
    }

    func insertAutocomplete(_ entry: EditorAgentCompletion) {
        guard let token = EditorAgentCompletionToken.current(in: prompt, cursorOffset: promptCaretOffset) else {
            return
        }
        let value: String
        switch entry {
        case let .file(file):
            value = "@" + EditorAgentPathTokens.escapedTokenValue(file.path)
        case let .skill(skill):
            let needsQualifier = token.marker == "@" || currentSessionConfiguration.commands.contains { $0.name == skill.id }
            value = String(token.marker) + (needsQualifier ? "skill:" : "") + EditorAgentPathTokens.escapedTokenValue(skill.id)
        case let .command(command):
            value = "/" + command.name
        }
        let prefix = String(prompt[..<token.range.lowerBound])
        prompt.replaceSubrange(token.range, with: value + " ")
        promptCaretOffset = prefix.count + value.count + 1
        let beforeCaret = prefix + value + " "
        let lines = beforeCaret.split(separator: "\n", omittingEmptySubsequences: false)
        let position = TextEditorSourcePosition(line: lines.count - 1, column: lines.last?.count ?? 0)
        promptCompletionFocus = TextEditorSourceRange(start: position, end: position)
        autocompleteSuggestions = []
        Task { @MainActor in
            focusCompletionPrompt()
        }
    }

    func dismissCompletions() {
        autocompleteSuggestions = []
        selectedCompletionIndex = 0
    }

    private func focusCompletionPrompt() {
        guard let window = UIWindowManager.shared?.activeWindow else {
            return
        }
        for container in window.uiInspectableContainers() {
            guard let prompt = try? container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Prompt")) else {
                continue
            }
            let point = Point(prompt.absoluteFrame.minX + 12, prompt.absoluteFrame.minY + 12)
            guard let hit = container.uiHitTest(at: point)?.node else {
                continue
            }
            if (try? container.uiFocusNode(matching: .runtimeID(hit.runtimeId))) != nil {
                return
            }
        }
    }

    func sendPromptAsync() async {
        guard !isSending else {
            return
        }
        guard
            var session = activeSession,
            let projectConfig,
            let projectURL
        else {
            statusMessage = "No active agent session."
            return
        }

        connectionSettings = projectConfig.ai.agent
        refreshSkills()
        if session.agentTargetIdentity != settings.configuration.target.sessionIdentity {
            session.upstreamSessionID = nil
        }
        session.agentTargetIdentity = settings.configuration.target.sessionIdentity
        let preparedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let invokedSkills = skillsInvokedByPrompt(preparedPrompt)
        let visibleRequestSkills = uniqueSkills(selectedSkills + invokedSkills)
        let coreSkills = availableSkills.filter { $0.id == "ada-project-orientation" }
        let requestSkills = uniqueSkills(coreSkills + visibleRequestSkills)
        let requestPrompt = promptRemovingSkillSlashCommand(preparedPrompt, invokedSkills: invokedSkills)

        let tokenAttachments = EditorAgentPathTokens.attachmentPaths(in: preparedPrompt)
            .compactMap { path -> EditorAgentAttachment? in
                guard !path.hasPrefix("skill:") else {
                    return nil
                }
                let url = projectURL.appendingPathComponent(path).standardizedFileURL
                guard fileManager.fileExists(atPath: url.path) else {
                    return nil
                }
                return EditorAgentAttachmentContext.attachment(forFileAt: url, projectURL: projectURL, fileManager: fileManager)
            }
        let attachmentsToSend = uniqueAttachments(pendingAttachments + tokenAttachments)

        let userSegments =
            [
                EditorAgentMessageSegment(kind: .text, text: preparedPrompt)
            ]
            + attachmentsToSend.map {
                EditorAgentMessageSegment(kind: .attachment, attachment: $0)
            }
            + visibleRequestSkills.map {
                EditorAgentMessageSegment(kind: .skill, skill: $0)
            }

        session.events.append(
            EditorAgentEvent(
                kind: .message,
                message: EditorAgentMessage(role: .user, segments: userSegments)
            )
        )
        session.attachments.append(contentsOf: attachmentsToSend)
        session.selectedSkillIDs = Array(selectedSkillIDs).sorted()
        session.updatedAt = Date()
        activeSession = session
        prompt = ""
        autocompleteSuggestions = []
        let attachments = attachmentsToSend
        let codeSelectionToSend = codeSelection
        pendingAttachments = []
        codeSelection = nil
        isSending = true
        connectionState = .connecting
        await saveActiveSession()
        runningSession = session
        let sessionID = session.id
        let activityID = notifications.activities.begin(
            .init(
                source: .agent,
                title: sessionConfiguration.agentName ?? "Agent",
                projectName: project?.name,
                action: .init(title: "Open chat", destination: .chat, projectID: project?.id, sessionID: sessionID)
            ),
            cancel: { [weak self] in
                guard let self else {
                    return
                }
                Task { await self.service.cancel(sessionID: sessionID) }
            }
        )
        runningActivityID = activityID
        lastActivityID = activityID

        do {
            connectionState = .running
            let result = try await service.send(
                EditorAgentRunRequest(
                    project: projectConfig,
                    projectURL: projectURL,
                    session: session,
                    mode: mode,
                    prompt: requestPrompt,
                    attachments: attachments,
                    sceneContext: sceneContext,
                    codeSelection: codeSelectionToSend,
                    skills: requestSkills,
                    availableSkills: availableSkills
                ),
                onEvent: { [weak self] event in
                    await MainActor.run {
                        self?.receiveRunEvent(event, sessionID: sessionID, activityID: activityID)
                    }
                },
                onProjectFileChanged: { [weak self] relativePath in
                    await MainActor.run {
                        self?.onProjectFileChanged(relativePath)
                    }
                }
            )
            runningSession?.upstreamSessionID = result.upstreamSessionID
            if activeSession?.id == sessionID {
                activeSession?.upstreamSessionID = result.upstreamSessionID
                sessionConfiguration = result.configuration
                connectionState = .ready(result.configuration.agentName)
            }
            let cancelled = !notifications.activities.active.contains { $0.id == activityID } || result.stopReason == "cancelled"
            receiveRunEvent(
                EditorAgentEvent(kind: .runStatus, title: cancelled ? "Interrupted" : "Done", details: result.stopReason),
                sessionID: sessionID,
                activityID: activityID
            )
            notifications.activities.finish(activityID, state: cancelled ? .cancelled : .completed)
        } catch {
            let cancelled = !notifications.activities.active.contains { $0.id == activityID } || error is CancellationError
            receiveRunEvent(
                EditorAgentEvent(
                    kind: .error,
                    title: cancelled ? "Interrupted" : "Agent failed",
                    details: error.localizedDescription,
                    isSuccessful: false
                ),
                sessionID: sessionID,
                activityID: activityID
            )
            notifications.activities.finish(activityID, state: cancelled ? .cancelled : .failed, detail: error.localizedDescription)
            if activeSession?.id == sessionID {
                connectionState = cancelled ? .disconnected : .failed(error.localizedDescription)
            }
        }
        if let store, let runningSession {
            do {
                try await store.saveSession(runningSession, makeActive: activeSession?.id == sessionID)
                sessions = try await store.listSessions()
            } catch { statusMessage = error.localizedDescription }
        }
        runningSession = nil
        runningActivityID = nil
        permissionActivityIDs = permissionActivityIDs.filter { $0.value != activityID }
        isSending = false
    }

    private func receiveRunEvent(_ event: EditorAgentEvent, sessionID: String, activityID: String) {
        guard runningSession?.id == sessionID, runningActivityID == activityID else {
            return
        }
        if let permission = event.permission {
            if permission.state == .pending {
                permissionActivityIDs[permission.id] = activityID
                notifications.activities.needsAttention(activityID, detail: permission.summary, eventID: "\(activityID):permission:\(permission.id)")
            } else {
                permissionActivityIDs.removeValue(forKey: permission.id)
                if !permissionActivityIDs.values.contains(activityID) {
                    notifications.activities.resume(activityID)
                }
            }
        } else if let tool = event.toolCall {
            notifications.activities.update(activityID, detail: tool.title)
        } else if event.kind == .runStatus, let title = event.title {
            notifications.activities.update(activityID, detail: title)
        }
        if activeSession?.id == sessionID {
            appendEvent(event)
            runningSession = activeSession
        } else if event.configuration == nil, var session = runningSession {
            EditorAgentEventReducer.upsert(event, into: &session.events)
            session.updatedAt = Date()
            runningSession = session
        }
    }

    private func connectAsync() async {
        guard
            let session = activeSession,
            let projectConfig,
            let projectURL
        else {
            statusMessage = "No active agent session."
            return
        }

        connectionSettings = projectConfig.ai.agent
        refreshSkills()
        connectionState = .connecting
        do {
            let configuration = try await service.connect(
                EditorAgentRunRequest(
                    project: projectConfig,
                    projectURL: projectURL,
                    session: session,
                    mode: mode,
                    prompt: "",
                    attachments: [],
                    sceneContext: nil,
                    codeSelection: nil,
                    skills: [],
                    availableSkills: availableSkills
                ),
                onEvent: { [weak self] event in
                    await MainActor.run {
                        self?.appendEvent(event)
                    }
                },
                onProjectFileChanged: { [weak self] relativePath in
                    await MainActor.run {
                        self?.onProjectFileChanged(relativePath)
                    }
                }
            )
            guard activeSession?.id == session.id, connectionSettings == settings.configuration else { return }
            sessionConfiguration = configuration
            connectionState = .ready(configuration.agentName)
        } catch {
            guard activeSession?.id == session.id, connectionSettings == settings.configuration else { return }
            statusMessage = error.localizedDescription
            connectionState = .failed(error.localizedDescription)
            notifications.post(
                .init(
                    source: .agent,
                    importance: .error,
                    title: "Agent connection failed",
                    detail: error.localizedDescription,
                    projectName: project?.name,
                    actions: [.init(title: "Agent settings", destination: .agentSettings, projectID: project?.id)]
                )
            )
        }
    }

    private func refreshSkills() {
        guard let projectURL else {
            return
        }
        availableSkills = EditorAgentSkillStore.discoverSkills(
            projectURL: projectURL,
            directories: settings.configuration.skillsDirectories,
            fileManager: fileManager
        )
    }

    private static func lineList(from text: String) -> [String] {
        text.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ",")))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func environment(from text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in lineList(from: text) {
            guard let separator = line.firstIndex(of: "=") else {
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                continue
            }
            result[key] = value
        }
        return result
    }

    private func appendEvent(_ event: EditorAgentEvent) {
        if let configuration = event.configuration {
            sessionConfiguration = configuration
            updateAutocomplete()
            return
        }
        guard var session = activeSession else {
            return
        }

        EditorAgentEventReducer.upsert(event, into: &session.events)

        session.updatedAt = Date()
        if let userText = session.events.compactMap(\.message).first(where: { $0.role == .user })?.segments.first?.text {
            session.title = String(userText.prefix(48)).nilIfEmpty ?? session.title
        }
        activeSession = session
    }

    private func saveActiveSession() async {
        guard let store, let activeSession else {
            return
        }
        do {
            try await store.saveSession(activeSession, makeActive: true)
            sessions = try await store.listSessions()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func updateAutocomplete() {
        guard let token = EditorAgentCompletionToken.current(in: prompt, cursorOffset: promptCaretOffset) else {
            autocompleteSuggestions = []
            selectedCompletionIndex = 0
            return
        }
        var results =
            availableSkills.filter {
                $0.userInvocable && (token.matches($0.id) || token.matches($0.name) || token.matches($0.description ?? ""))
            }
            .map(EditorAgentCompletion.skill)
        if token.marker == "/", !token.query.hasPrefix("skill:") {
            results += currentSessionConfiguration.commands
                .filter {
                    token.matches($0.name) || token.matches($0.description)
                }
                .map(EditorAgentCompletion.command)
        } else if token.marker == "@", !token.query.hasPrefix("skill:"), let projectURL {
            results += EditorAgentProjectFileSearch.search(projectURL: projectURL, query: token.query, limit: 8, fileManager: fileManager)
                .map(EditorAgentCompletion.file)
        }
        let query = token.query.lowercased()
        func rank(_ entry: EditorAgentCompletion) -> Int {
            let title = entry.title.lowercased()
            return title == query ? 0 : title.hasPrefix(query) ? 1 : 2
        }
        let sorted = results.sorted {
            rank($0) == rank($1) ? $0.id.localizedStandardCompare($1.id) == .orderedAscending : rank($0) < rank($1)
        }
        let updated = Array(sorted.prefix(12))
        if autocompleteSuggestions != updated {
            selectedCompletionIndex = 0
        }
        autocompleteSuggestions = updated
    }

    private func skillsInvokedByPrompt(_ prompt: String) -> [EditorAgentSkill] {
        let slashName = prompt.hasPrefix("/") ? String(prompt.dropFirst().prefix { !$0.isWhitespace }) : ""
        let explicitSlash = slashName.hasPrefix("skill:")
        let slashID = explicitSlash ? String(slashName.dropFirst(6)) : slashName
        let isAgentCommand = !explicitSlash && currentSessionConfiguration.commands.contains { $0.name == slashID }
        let mentions = Set(
            EditorAgentPathTokens.attachmentPaths(in: prompt)
                .compactMap { token -> String? in
                    token.hasPrefix("skill:") ? String(token.dropFirst(6)) : nil
                }
        )
        return availableSkills.filter {
            $0.userInvocable && (mentions.contains($0.id) || (!isAgentCommand && ($0.id == slashID || $0.name == slashID)))
        }
    }

    private func promptRemovingSkillSlashCommand(_ prompt: String, invokedSkills: [EditorAgentSkill]) -> String {
        guard
            prompt.hasPrefix("/"), let first = prompt.split(whereSeparator: \.isWhitespace).first,
            invokedSkills.contains(where: { ["/" + $0.id, "/" + $0.name, "/skill:" + $0.id].contains(String(first)) })
        else {
            return prompt
        }
        return String(prompt.dropFirst(first.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func uniqueAttachments(_ attachments: [EditorAgentAttachment]) -> [EditorAgentAttachment] {
        var seen = Set<String>()
        var result: [EditorAgentAttachment] = []
        for attachment in attachments where !seen.contains(attachment.absolutePath) {
            seen.insert(attachment.absolutePath)
            result.append(attachment)
        }
        return result
    }

    private func uniqueSkills(_ skills: [EditorAgentSkill]) -> [EditorAgentSkill] {
        var seen = Set<String>()
        return skills.filter { seen.insert($0.id).inserted }
    }
}

enum EditorAgentEventReducer {
    static func upsert(_ event: EditorAgentEvent, into events: inout [EditorAgentEvent]) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else {
            events.append(event)
            return
        }

        if event.isDelta == true,
            var existingMessage = events[index].message,
            let deltaMessage = event.message,
            let deltaSegment = deltaMessage.segments.first,
            let segmentIndex = existingMessage.segments.firstIndex(where: { $0.kind == deltaSegment.kind }) {
            let existingText = existingMessage.segments[segmentIndex].text ?? ""
            existingMessage.segments[segmentIndex].text = existingText + (deltaSegment.text ?? "")
            events[index].message = existingMessage
            events[index].createdAt = event.createdAt
            return
        }

        if let incomingTool = event.toolCall, var currentTool = events[index].toolCall {
            if incomingTool.title != "Tool call" {
                currentTool.title = incomingTool.title
            }
            if incomingTool.kind != "other" {
                currentTool.kind = incomingTool.kind
            }
            currentTool.status = incomingTool.status ?? currentTool.status
            if !incomingTool.content.isEmpty {
                currentTool.content = incomingTool.content
            }
            if !incomingTool.locations.isEmpty {
                currentTool.locations = incomingTool.locations
            }
            var merged = event
            merged.toolCall = currentTool
            merged.title = currentTool.title
            events[index] = merged
            return
        }

        events[index] = event
    }
}
