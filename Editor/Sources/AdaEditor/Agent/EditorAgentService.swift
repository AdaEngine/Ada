import Foundation

#if canImport(ACP) && canImport(ACPModel)
    import ACP
    import ACPModel
#endif

struct EditorAgentRunRequest: Sendable {
    var project: AdaProject
    var projectURL: URL
    var session: EditorAgentSession
    var mode: EditorAgentChatMode
    var prompt: String
    var attachments: [EditorAgentAttachment]
    var sceneContext: EditorAgentSceneContext?
    var codeSelection: EditorAgentCodeSelectionContext?
    var skills: [EditorAgentSkill]
    var availableSkills: [EditorAgentSkill] = []
}

struct EditorAgentRunResult: Sendable {
    var upstreamSessionID: String?
    var assistantText: String
    var stopReason: String
    var configuration: EditorAgentSessionConfiguration
}

protocol EditorAgentServicing: Sendable {
    func connect(
        _ request: EditorAgentRunRequest,
        onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void,
        onProjectFileChanged: @escaping @Sendable (String) async -> Void
    ) async throws -> EditorAgentSessionConfiguration
    func send(
        _ request: EditorAgentRunRequest,
        onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void,
        onProjectFileChanged: @escaping @Sendable (String) async -> Void
    ) async throws -> EditorAgentRunResult
    func setConfiguration(sessionID: String, selectorID: String, valueID: String) async throws -> EditorAgentSessionConfiguration
    func resolvePermission(requestID: String, optionID: String?) async
    func cancel(sessionID: String) async
    func shutdown() async
}

enum EditorAgentServiceError: Error, LocalizedError, Sendable {
    case disabled
    case missingCommand
    case unsupportedPlatform
    case sessionUnavailable
    case pathOutsideProject(String)
    case providerFailure(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            "Enable an agent in global settings."
        case .missingCommand:
            "ACP target command is not configured."
        case .unsupportedPlatform:
            "ACP agent integration is unavailable on this platform."
        case .sessionUnavailable:
            "ACP session is unavailable."
        case let .providerFailure(message):
            message
        case let .pathOutsideProject(path):
            "Agent path is outside the project: \(path)"
        }
    }
}

#if canImport(ACP) && canImport(ACPModel)
    private actor EditorAgentPermissionBroker {
        private struct PendingPermission {
            var sessionID: String
            var continuation: CheckedContinuation<String?, Never>
        }

        private var continuations: [String: PendingPermission] = [:]

        func request(id: String, sessionID: String) async -> String? {
            await withCheckedContinuation { continuation in
                continuations[id] = PendingPermission(sessionID: sessionID, continuation: continuation)
            }
        }

        func resolve(id: String, optionID: String?) {
            continuations.removeValue(forKey: id)?.continuation.resume(returning: optionID)
        }

        func cancel(sessionID: String) {
            let ids = continuations.compactMap { id, pending in
                pending.sessionID == sessionID ? id : nil
            }
            for id in ids {
                continuations.removeValue(forKey: id)?.continuation.resume(returning: nil)
            }
        }

        func cancelAll() {
            let pending = continuations.values.map(\.continuation)
            continuations.removeAll()
            for continuation in pending {
                continuation.resume(returning: nil)
            }
        }
    }

    private actor EditorACPEventSink {
        var onEvent: @Sendable (EditorAgentEvent) async -> Void
        var onFileChanged: @Sendable (String) async -> Void

        init(onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void, onFileChanged: @escaping @Sendable (String) async -> Void) {
            self.onEvent = onEvent
            self.onFileChanged = onFileChanged
        }

        func update(onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void, onFileChanged: @escaping @Sendable (String) async -> Void) {
            self.onEvent = onEvent
            self.onFileChanged = onFileChanged
        }

        func emit(_ event: EditorAgentEvent) async { await onEvent(event) }
        func fileChanged(_ path: String) async { await onFileChanged(path) }
    }

    actor EditorACPAgentService: EditorAgentServicing {
        private struct ManagedSession {
            var client: Client
            var eventSink: EditorACPEventSink
            var agentSettings: AdaProjectAgent
            var upstreamSessionID: SessionId
            var supportsLoadSession: Bool
            var agentName: String?
            var notificationTask: Task<Void, Never>
            var assistantText: String
            var assistantEventID: String
            var thinkingEventID: String
            var configuration: EditorAgentSessionConfiguration
        }

        private var sessions: [String: ManagedSession] = [:]
        private let permissionBroker = EditorAgentPermissionBroker()

        func connect(
            _ request: EditorAgentRunRequest,
            onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void,
            onProjectFileChanged: @escaping @Sendable (String) async -> Void
        ) async throws -> EditorAgentSessionConfiguration {
            let managed = try await prepareSession(
                request: request,
                onEvent: onEvent,
                onProjectFileChanged: onProjectFileChanged
            )
            return managed.configuration
        }

        func send(
            _ request: EditorAgentRunRequest,
            onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void,
            onProjectFileChanged: @escaping @Sendable (String) async -> Void
        ) async throws -> EditorAgentRunResult {
            guard request.project.ai.agent.enabled else {
                throw EditorAgentServiceError.disabled
            }

            var managed = try await prepareSession(
                request: request,
                onEvent: onEvent,
                onProjectFileChanged: onProjectFileChanged
            )
            managed.assistantText = ""
            managed.assistantEventID = UUID().uuidString
            managed.thinkingEventID = UUID().uuidString
            sessions[request.session.id] = managed

            let response = try await managed.client.sendPrompt(
                sessionId: managed.upstreamSessionID,
                content: try promptContent(for: request)
            )

            managed = sessions[request.session.id] ?? managed
            managed.assistantText = managed.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            sessions[request.session.id] = managed

            if let failure = EditorAgentProviderFailure.message(in: managed.assistantText) {
                throw EditorAgentServiceError.providerFailure(failure)
            }
            if managed.assistantText.isEmpty, response.stopReason.rawValue == "end_turn" {
                await onEvent(EditorAgentEvent(kind: .error, title: "No response received", details: "The agent finished without sending a reply. Check its connection and model settings."))
            }
            return EditorAgentRunResult(
                upstreamSessionID: managed.upstreamSessionID.value,
                assistantText: managed.assistantText,
                stopReason: response.stopReason.rawValue,
                configuration: managed.configuration
            )
        }

        func setConfiguration(sessionID: String, selectorID: String, valueID: String) async throws -> EditorAgentSessionConfiguration {
            guard
                var managed = sessions[sessionID],
                let selectorIndex = managed.configuration.selectors.firstIndex(where: { $0.id == selectorID })
            else {
                throw EditorAgentServiceError.sessionUnavailable
            }

            let selector = managed.configuration.selectors[selectorIndex]
            guard selector.choices.contains(where: { $0.id == valueID }) else {
                throw EditorAgentServiceError.sessionUnavailable
            }
            if selector.usesLegacyMethod {
                switch selector.category {
                case .mode:
                    _ = try await managed.client.setMode(sessionId: managed.upstreamSessionID, modeId: valueID)
                case .model:
                    _ = try await managed.client.setModel(sessionId: managed.upstreamSessionID, modelId: valueID)
                case .reasoning,
                    .other:
                    throw EditorAgentServiceError.sessionUnavailable
                }
                managed.configuration.selectors[selectorIndex].currentValueID = valueID
            } else {
                let response = try await managed.client.setConfigOption(
                    sessionId: managed.upstreamSessionID,
                    configId: SessionConfigId(selectorID),
                    value: SessionConfigValueId(valueID)
                )
                let updated = Self.configuration(
                    agentName: managed.agentName,
                    modes: nil,
                    models: nil,
                    configOptions: response.configOptions
                )
                let legacy = managed.configuration.selectors.filter { old in
                    old.usesLegacyMethod && !updated.selectors.contains { $0.category == old.category }
                }
                managed.configuration = EditorAgentSessionConfiguration(agentName: managed.agentName, selectors: updated.selectors + legacy, commands: managed.configuration.commands)
            }
            sessions[sessionID] = managed
            return managed.configuration
        }

        func resolvePermission(requestID: String, optionID: String?) async {
            await permissionBroker.resolve(id: requestID, optionID: optionID)
        }

        func cancel(sessionID: String) async {
            await permissionBroker.cancel(sessionID: sessionID)
            guard let managed = sessions[sessionID] else {
                return
            }
            try? await managed.client.cancelSession(sessionId: managed.upstreamSessionID)
        }

        func shutdown() async {
            await permissionBroker.cancelAll()
            for session in sessions.values {
                session.notificationTask.cancel()
                await session.client.terminate()
            }
            sessions.removeAll()
        }

        private func prepareSession(
            request: EditorAgentRunRequest,
            onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void,
            onProjectFileChanged: @escaping @Sendable (String) async -> Void
        ) async throws -> ManagedSession {
            let agentConfig = request.project.ai.agent
            guard agentConfig.enabled else {
                throw EditorAgentServiceError.disabled
            }
            if let existing = sessions[request.session.id] {
                if existing.agentSettings == agentConfig {
                    await existing.eventSink.update(onEvent: onEvent, onFileChanged: onProjectFileChanged)
                    return existing
                }
                existing.notificationTask.cancel()
                await existing.client.terminate()
                sessions.removeValue(forKey: request.session.id)
            }
            guard let command = agentConfig.target.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
                throw EditorAgentServiceError.missingCommand
            }

            let client = Client()
            let eventSink = EditorACPEventSink(onEvent: onEvent, onFileChanged: onProjectFileChanged)
            let projectURL = request.projectURL.standardizedFileURL
            let delegate = EditorACPClientDelegate(
                localSessionID: request.session.id,
                projectURL: projectURL,
                permissionMode: agentConfig.permissionMode,
                permissionBroker: permissionBroker,
                onEvent: { await eventSink.emit($0) },
                onProjectFileChanged: { await eventSink.fileChanged($0) }
            )
            await client.setDelegate(delegate)

            let workingDirectory = effectiveWorkingDirectory(projectURL: projectURL, target: agentConfig.target)
            try await client.launch(
                agentPath: command,
                arguments: agentConfig.target.arguments,
                workingDirectory: workingDirectory.path,
                environment: agentConfig.target.environment
            )
            let initialized = try await client.initialize(
                capabilities: ClientCapabilities(
                    fs: FileSystemCapabilities(readTextFile: true, writeTextFile: true),
                    terminal: true
                ),
                clientInfo: ClientInfo(name: "AdaEditor", title: "Ada Editor", version: "1.0.0"),
                timeout: 30
            )

            let upstreamSessionID: SessionId
            let modes: ModesInfo?
            let models: ModelsInfo?
            let configOptions: [SessionConfigOption]?
            let supportsLoadSession = initialized.agentCapabilities.loadSession == true
            if let upstream = request.session.upstreamSessionID, supportsLoadSession, request.session.agentTargetIdentity == agentConfig.target.sessionIdentity {
                let response = try await client.loadSession(sessionId: SessionId(upstream), cwd: workingDirectory.path)
                upstreamSessionID = response.sessionId
                modes = response.modes
                models = response.models
                configOptions = response.configOptions
            } else {
                let response = try await client.newSession(
                    workingDirectory: workingDirectory.path,
                    mcpServers: mcpServers(for: request.project),
                    timeout: 30
                )
                upstreamSessionID = response.sessionId
                modes = response.modes
                models = response.models
                configOptions = response.configOptions
            }

            let localSessionID = request.session.id
            let notificationTask = Task { [weak self] in
                for await notification in await client.notifications {
                    await self?
                        .handleNotification(
                            localSessionID: localSessionID,
                            upstreamSessionID: upstreamSessionID,
                            notification: notification,
                            onEvent: { await eventSink.emit($0) }
                        )
                }
            }

            let agentName = initialized.agentInfo?.title ?? initialized.agentInfo?.name
            let managed = ManagedSession(
                client: client,
                eventSink: eventSink,
                agentSettings: agentConfig,
                upstreamSessionID: upstreamSessionID,
                supportsLoadSession: supportsLoadSession,
                agentName: agentName,
                notificationTask: notificationTask,
                assistantText: "",
                assistantEventID: UUID().uuidString,
                thinkingEventID: UUID().uuidString,
                configuration: Self.configuration(
                    agentName: agentName,
                    modes: modes,
                    models: models,
                    configOptions: configOptions
                )
            )
            sessions[localSessionID] = managed
            await onEvent(EditorAgentEvent(kind: .runStatus, configuration: managed.configuration))
            return managed
        }

        private func mcpServers(for project: AdaProject) -> [MCPServerConfig] {
            guard project.ai.mcp.enabled else {
                return []
            }
            return [
                .http(HTTPServerConfig(name: "AdaEditor Runtime", url: "http://127.0.0.1:2510/mcp"))
            ]
        }

        private static func configuration(
            agentName: String?,
            modes: ModesInfo?,
            models: ModelsInfo?,
            configOptions: [SessionConfigOption]?
        ) -> EditorAgentSessionConfiguration {
            var selectors = (configOptions ?? []).compactMap(configurationSelector)
            if selectors.contains(where: { $0.category == .mode }) == false, let modes {
                selectors.append(
                    EditorAgentConfigurationSelector(
                        id: "mode",
                        name: "Mode",
                        category: .mode,
                        currentValueID: modes.currentModeId,
                        choices: modes.availableModes.map { .init(id: $0.id, name: $0.name, description: $0.description) },
                        usesLegacyMethod: true
                    )
                )
            }
            if selectors.contains(where: { $0.category == .model }) == false, let models {
                selectors.append(
                    EditorAgentConfigurationSelector(
                        id: "model",
                        name: "Model",
                        category: .model,
                        currentValueID: models.currentModelId,
                        choices: models.availableModels.map { .init(id: $0.modelId, name: $0.name, description: $0.description) },
                        usesLegacyMethod: true
                    )
                )
            }
            return EditorAgentSessionConfiguration(agentName: agentName, selectors: selectors)
        }

        private static func configurationSelector(_ option: SessionConfigOption) -> EditorAgentConfigurationSelector? {
            guard case let .select(select) = option.kind else {
                return nil
            }
            let choices: [EditorAgentConfigurationChoice] =
                switch select.options {
                case let .ungrouped(options):
                    options.map { .init(id: $0.value.value, name: $0.name, description: $0.description) }
                case let .grouped(groups):
                    groups.flatMap { group in
                        group.options.map { .init(id: $0.value.value, name: $0.name, description: $0.description) }
                    }
                }
            let normalizedCategory = (option.category ?? option.id.value).lowercased()
            let category: EditorAgentConfigurationCategory =
                switch normalizedCategory {
                case "mode": .mode
                case "model": .model
                case "thought_level",
                    "reasoning",
                    "reasoning_effort":
                    .reasoning
                default: .other
                }
            return EditorAgentConfigurationSelector(
                id: option.id.value,
                name: option.name,
                category: category,
                currentValueID: select.currentValue.value,
                choices: choices,
                usesLegacyMethod: false
            )
        }

        private func effectiveWorkingDirectory(projectURL: URL, target: AdaProjectAgentTarget) -> URL {
            guard let cwd = target.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else {
                return projectURL
            }
            return projectURL.appendingPathComponent(cwd, isDirectory: true).standardizedFileURL
        }

        private func promptContent(for request: EditorAgentRunRequest) throws -> [ContentBlock] {
            let text = EditorAgentPromptContext.text(for: request)
            var content: [ContentBlock] = [.text(TextContent(text: text))]
            for attachment in request.attachments where attachment.mimeType.hasPrefix("image/") {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: attachment.absolutePath)) else {
                    continue
                }
                content.append(
                    .image(
                        ImageContent(
                            data: data.base64EncodedString(),
                            mimeType: attachment.mimeType,
                            uri: URL(fileURLWithPath: attachment.absolutePath).absoluteString
                        )
                    )
                )
            }
            return content
        }

        private func handleNotification(
            localSessionID: String,
            upstreamSessionID: SessionId,
            notification: JSONRPCNotification,
            onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void
        ) async {
            guard
                notification.method == "session/update",
                let payload = decode(notification: notification, as: SessionUpdateNotification.self),
                payload.sessionId == upstreamSessionID,
                var managed = sessions[localSessionID]
            else {
                return
            }

            switch payload.update {
            case let .availableCommandsUpdate(commands):
                managed.configuration.commands = commands.map {
                    EditorAgentCommand(name: $0.name, description: $0.description, inputHint: $0.input?.hint)
                }
                sessions[localSessionID] = managed
                await onEvent(EditorAgentEvent(kind: .runStatus, configuration: managed.configuration))
            case let .configOptionUpdate(options):
                let updated = Self.configuration(agentName: managed.agentName, modes: nil, models: nil, configOptions: options)
                // Preserve legacy selectors when the provider only updates modern config options.
                let legacy = managed.configuration.selectors.filter { old in
                    old.usesLegacyMethod && !updated.selectors.contains { $0.category == old.category }
                }
                managed.configuration = EditorAgentSessionConfiguration(agentName: managed.agentName, selectors: updated.selectors + legacy, commands: managed.configuration.commands)
                sessions[localSessionID] = managed
                await onEvent(EditorAgentEvent(kind: .runStatus, configuration: managed.configuration))
            case let .currentModeUpdate(modeID):
                if let index = managed.configuration.selectors.firstIndex(where: { $0.category == .mode }) {
                    managed.configuration.selectors[index].currentValueID = modeID
                    sessions[localSessionID] = managed
                    await onEvent(EditorAgentEvent(kind: .runStatus, configuration: managed.configuration))
                }
            case let .agentMessageChunk(block):
                let text = flatten(content: block)
                guard !text.isEmpty else {
                    return
                }
                managed.assistantText += text
                sessions[localSessionID] = managed
                await onEvent(
                    EditorAgentEvent(
                        id: managed.assistantEventID,
                        kind: .message,
                        message: EditorAgentMessage(
                            id: managed.assistantEventID,
                            role: .assistant,
                            segments: [.init(kind: .text, text: text)]
                        ),
                        isDelta: true
                    )
                )
            case let .agentThoughtChunk(block):
                let text = flatten(content: block)
                guard !text.isEmpty else {
                    return
                }
                await onEvent(
                    EditorAgentEvent(
                        id: managed.thinkingEventID,
                        kind: .message,
                        message: EditorAgentMessage(
                            id: managed.thinkingEventID,
                            role: .assistant,
                            segments: [.init(kind: .thinking, text: text)]
                        ),
                        isDelta: true
                    )
                )
            case let .plan(plan):
                let text = plan.entries.map { "[\($0.status)] \($0.content)" }.joined(separator: "\n")
                guard !text.isEmpty else {
                    return
                }
                await onEvent(EditorAgentEvent(kind: .runStatus, title: "Plan", details: text))
            case let .toolCall(toolCall):
                let model = Self.toolCall(
                    id: toolCall.toolCallId,
                    title: toolCall.title,
                    kind: toolCall.kind,
                    status: toolCall.status,
                    content: toolCall.content,
                    locations: toolCall.locations
                )
                await onEvent(
                    EditorAgentEvent(
                        id: "tool-\(toolCall.toolCallId)",
                        kind: .toolCall,
                        title: model.title,
                        isSuccessful: model.status == .completed ? true : (model.status == .failed ? false : nil),
                        toolCall: model
                    )
                )
            case let .toolCallUpdate(details):
                let model = Self.toolCall(
                    id: details.toolCallId,
                    title: details.title,
                    kind: details.kind,
                    status: details.status,
                    content: details.content,
                    locations: details.locations
                )
                await onEvent(
                    EditorAgentEvent(
                        id: "tool-\(details.toolCallId)",
                        kind: .toolCall,
                        title: model.title,
                        isSuccessful: model.status == .completed ? true : (model.status == .failed ? false : nil),
                        toolCall: model
                    )
                )
            case let .sessionInfoUpdate(info):
                if let title = info.title {
                    await onEvent(EditorAgentEvent(kind: .runStatus, title: "Session updated", details: title))
                }
            default:
                break
            }
        }

        private func decode<T: Decodable>(notification: JSONRPCNotification, as type: T.Type) -> T? {
            guard
                let params = notification.params,
                let data = try? JSONEncoder().encode(params)
            else {
                return nil
            }
            return try? JSONDecoder().decode(type, from: data)
        }

        private func flatten(content: ContentBlock) -> String {
            switch content {
            case let .text(text):
                return text.text
            case let .resource(resource):
                return resource.resource.text ?? ""
            case let .resourceLink(link):
                return link.uri
            case .image,
                .audio:
                return ""
            }
        }

        private static func toolCall(
            id: String,
            title: String?,
            kind: ToolKind?,
            status: ToolStatus?,
            content: [ToolCallContent]?,
            locations: [ToolLocation]?
        ) -> EditorAgentToolCall {
            EditorAgentToolCall(
                id: id,
                title: title ?? kind?.rawValue ?? "Tool call",
                kind: kind?.rawValue ?? "other",
                status: editorStatus(status),
                content: (content ?? []).compactMap(editorContent),
                locations: (locations ?? []).map { .init(path: $0.path, line: $0.line) }
            )
        }

        private static func editorStatus(_ status: ToolStatus?) -> EditorAgentToolStatus? {
            switch status {
            case .pending:
                .pending
            case .inProgress:
                .inProgress
            case .completed:
                .completed
            case .failed:
                .failed
            case nil:
                nil
            }
        }

        private static func editorContent(_ content: ToolCallContent) -> EditorAgentToolContent? {
            switch content {
            case let .diff(diff):
                return .init(kind: .diff, path: diff.path, oldText: diff.oldText, newText: diff.newText)
            case let .terminal(terminal):
                return .init(kind: .terminal, terminalID: terminal.terminalId)
            case let .content(block):
                switch block {
                case let .text(text):
                    return .init(kind: .text, text: text.text)
                case let .image(image):
                    return .init(kind: .image, imageData: image.data, mimeType: image.mimeType, uri: image.uri)
                case let .resourceLink(resource):
                    return .init(kind: .resource, text: resource.title ?? resource.name, mimeType: resource.mimeType, uri: resource.uri)
                case let .resource(resource):
                    return .init(
                        kind: .resource,
                        text: resource.resource.text,
                        mimeType: resource.resource.mimeType,
                        uri: resource.resource.uri
                    )
                case .audio:
                    return nil
                }
            }
        }
    }
#else
    actor EditorACPAgentService: EditorAgentServicing {
        func connect(
            _: EditorAgentRunRequest,
            onEvent _: @escaping @Sendable (EditorAgentEvent) async -> Void,
            onProjectFileChanged _: @escaping @Sendable (String) async -> Void
        ) async throws -> EditorAgentSessionConfiguration {
            throw EditorAgentServiceError.unsupportedPlatform
        }

        func send(
            _: EditorAgentRunRequest,
            onEvent _: @escaping @Sendable (EditorAgentEvent) async -> Void,
            onProjectFileChanged _: @escaping @Sendable (String) async -> Void
        ) async throws -> EditorAgentRunResult {
            throw EditorAgentServiceError.unsupportedPlatform
        }

        func setConfiguration(sessionID _: String, selectorID _: String, valueID _: String) async throws -> EditorAgentSessionConfiguration {
            throw EditorAgentServiceError.unsupportedPlatform
        }

        func resolvePermission(requestID _: String, optionID _: String?) async {}

        func cancel(sessionID _: String) async {}

        func shutdown() async {}
    }
#endif

enum EditorAgentPromptContext {
    static func text(for request: EditorAgentRunRequest) -> String {
        var text = """
            [Mode: \(request.mode.rawValue)]
            """

        if let sceneContext = request.sceneContext {
            text += "\n\n\(sceneContextBlock(sceneContext))"
        }

        if let codeSelection = request.codeSelection {
            text += "\n\n\(codeSelectionBlock(codeSelection))"
        }

        text += "\n\n\(projectCapabilitiesBlock(request.project))"

        if !request.availableSkills.isEmpty {
            text += "\n\n\(skillCatalogBlock(request.availableSkills))"
        }

        text += "\n\n\(request.prompt)"

        for skill in request.skills where skill.userInvocable {
            text += "\n\n[Skill: \(skill.name)]\n\(skill.instructions)"
        }
        for attachment in request.attachments {
            text += "\n\n\(EditorAgentAttachmentContext.fileReferenceBlock(attachment: attachment))"
        }

        return text
    }

    private static func sceneContextBlock(_ context: EditorAgentSceneContext) -> String {
        var lines = [
            "[Scene Context]",
            "Scene: \(context.sceneTitle)",
            "Scene path: \(context.sceneRelativePath)",
            "Selected entity: \(context.selectedEntityName) (\(context.selectedEntityID))",
        ]

        if let parentID = context.parentID {
            lines.append("Parent entity id: \(parentID)")
        }

        if !context.componentNames.isEmpty {
            lines.append("Components: \(context.componentNames.joined(separator: ", "))")
        }

        lines.append("Selected entity YAML:")
        lines.append(context.entityYAML)
        return lines.joined(separator: "\n")
    }

    private static func codeSelectionBlock(_ context: EditorAgentCodeSelectionContext) -> String {
        """
        [Selected Code]
        File: \(context.documentRelativePath)
        Range: \(context.lineDescription)
        Language: \(context.language)
        ```\(context.language)
        \(context.text)
        ```
        """
    }

    private static func projectCapabilitiesBlock(_ project: AdaProject) -> String {
        let sources = project.paths.sources ?? "Sources"
        let assets = project.paths.assets ?? "Assets"
        return """
            [AdaEditor Project Capabilities]
            - Scene documents: *.ascn/*.scene/*.scn (YAML); edit them through project files and preserve schemaVersion.
            - Swift and Ada Script code: \(sources) (Swift: *.swift, Ada Script: *.ada).
            - Shaders: *.glsl/*.vert/*.frag/*.shader/*.metal under the project, commonly in \(assets).
            - Assets and project files: \(assets) and the project tree; project metadata is .ada/project.json.
            - The AdaEditor Runtime MCP server exposes live worlds, entities, components, assets, render captures, UI, traces, and profiler data.
            - After edits, run the narrowest relevant build or test and report failures precisely.
            """
    }

    private static func skillCatalogBlock(_ skills: [EditorAgentSkill]) -> String {
        let entries = skills.map { skill in
            let description = skill.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            return "- /\(skill.id): \(description?.isEmpty == false ? description ?? skill.name : skill.name)"
        }
        return
            ([
                "[Available AdaEditor Skills]",
                "Use a matching skill when its workflow applies. Full instructions for active skills follow below.",
            ] + entries)
            .joined(separator: "\n")
    }
}

#if canImport(ACP) && canImport(ACPModel)
    private actor EditorACPClientDelegate: ClientDelegate {
        private let terminalDelegate = TerminalDelegate()
        private let localSessionID: String
        private let projectURL: URL
        private let permissionMode: AdaProjectAgentPermissionMode
        private let permissionBroker: EditorAgentPermissionBroker
        private let onEvent: @Sendable (EditorAgentEvent) async -> Void
        private let onProjectFileChanged: @Sendable (String) async -> Void

        init(
            localSessionID: String,
            projectURL: URL,
            permissionMode: AdaProjectAgentPermissionMode,
            permissionBroker: EditorAgentPermissionBroker,
            onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void,
            onProjectFileChanged: @escaping @Sendable (String) async -> Void
        ) {
            self.localSessionID = localSessionID
            self.projectURL = projectURL.standardizedFileURL
            self.permissionMode = permissionMode
            self.permissionBroker = permissionBroker
            self.onEvent = onEvent
            self.onProjectFileChanged = onProjectFileChanged
        }

        func handleFileReadRequest(_ path: String, sessionId _: String, line: Int?, limit: Int?) async throws -> ReadTextFileResponse {
            let url = try resolvedProjectURL(path)
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            let filtered: String
            if let line, let limit {
                let start = max(0, line - 1)
                let end = min(lines.count, start + limit)
                filtered = lines[start..<end].joined(separator: "\n")
            } else if let line {
                let start = max(0, line - 1)
                filtered = lines[start...].joined(separator: "\n")
            } else {
                filtered = content
            }
            return ReadTextFileResponse(content: filtered, totalLines: lines.count)
        }

        func handleFileWriteRequest(_ path: String, content: String, sessionId _: String) async throws -> WriteTextFileResponse {
            let url = try resolvedProjectURL(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            await onProjectFileChanged(relativePath(for: url))
            return WriteTextFileResponse()
        }

        func handleTerminalCreate(command: String, sessionId: String, args: [String]?, cwd: String?, env: [EnvVariable]?, outputByteLimit: Int?) async throws -> CreateTerminalResponse {
            if let cwd {
                _ = try resolvedProjectURL(cwd)
            }
            return try await terminalDelegate.handleTerminalCreate(
                command: command,
                sessionId: sessionId,
                args: args,
                cwd: cwd ?? projectURL.path,
                env: env,
                outputByteLimit: outputByteLimit
            )
        }

        func handleTerminalOutput(terminalId: TerminalId, sessionId: String) async throws -> TerminalOutputResponse {
            try await terminalDelegate.handleTerminalOutput(terminalId: terminalId, sessionId: sessionId)
        }

        func handleTerminalWaitForExit(terminalId: TerminalId, sessionId: String) async throws -> WaitForExitResponse {
            try await terminalDelegate.handleTerminalWaitForExit(terminalId: terminalId, sessionId: sessionId)
        }

        func handleTerminalKill(terminalId: TerminalId, sessionId: String) async throws -> KillTerminalResponse {
            try await terminalDelegate.handleTerminalKill(terminalId: terminalId, sessionId: sessionId)
        }

        func handleTerminalRelease(terminalId: TerminalId, sessionId: String) async throws -> ReleaseTerminalResponse {
            try await terminalDelegate.handleTerminalRelease(terminalId: terminalId, sessionId: sessionId)
        }

        func handlePermissionRequest(request: RequestPermissionRequest) async throws -> RequestPermissionResponse {
            let summary =
                request.message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? request.toolCall.map { "Permission requested for tool call \($0.toolCallId)" }
                ?? "Permission requested"
            let requestID = "permission-\(request.toolCall?.toolCallId ?? UUID().uuidString)"
            let options = (request.options ?? [])
                .map {
                    EditorAgentPermissionOption(id: $0.optionId, name: $0.name, kind: $0.kind)
                }
            let pending = EditorAgentPermissionRequest(
                id: requestID,
                summary: summary,
                toolCallID: request.toolCall?.toolCallId,
                options: options,
                state: .pending,
                selectedOptionID: nil
            )
            await onEvent(
                EditorAgentEvent(
                    id: requestID,
                    kind: .permission,
                    title: "Approval required",
                    details: summary,
                    permission: pending
                )
            )

            guard permissionMode != .deny else {
                await onEvent(
                    EditorAgentEvent(
                        id: requestID,
                        kind: .permission,
                        title: "Denied",
                        details: summary,
                        isSuccessful: false,
                        permission: .init(
                            id: requestID,
                            summary: summary,
                            toolCallID: request.toolCall?.toolCallId,
                            options: options,
                            state: .cancelled,
                            selectedOptionID: nil
                        )
                    )
                )
                return RequestPermissionResponse(outcome: PermissionOutcome(cancelled: true))
            }

            let selectedOptionID = await permissionBroker.request(id: requestID, sessionID: localSessionID)
            let selectedOption = options.first { $0.id == selectedOptionID }
            let allowed = selectedOption?.kind.hasPrefix("allow") == true
            await onEvent(
                EditorAgentEvent(
                    id: requestID,
                    kind: .permission,
                    title: selectedOption?.name ?? "Cancelled",
                    details: summary,
                    isSuccessful: selectedOptionID == nil ? false : allowed,
                    permission: .init(
                        id: requestID,
                        summary: summary,
                        toolCallID: request.toolCall?.toolCallId,
                        options: options,
                        state: selectedOptionID == nil ? .cancelled : .selected,
                        selectedOptionID: selectedOptionID
                    )
                )
            )
            if let selectedOptionID {
                return RequestPermissionResponse(outcome: PermissionOutcome(optionId: selectedOptionID))
            }
            return RequestPermissionResponse(outcome: PermissionOutcome(cancelled: true))
        }

        private func resolvedProjectURL(_ path: String) throws -> URL {
            let candidate: URL
            if path.hasPrefix("/") {
                candidate = URL(fileURLWithPath: path).standardizedFileURL
            } else {
                candidate = projectURL.appendingPathComponent(path).standardizedFileURL
            }
            guard candidate.path == projectURL.path || candidate.path.hasPrefix(projectURL.path + "/") else {
                throw EditorAgentServiceError.pathOutsideProject(path)
            }
            return candidate
        }

        private func relativePath(for url: URL) -> String {
            let standardized = url.standardizedFileURL
            guard standardized.path.hasPrefix(projectURL.path + "/") else {
                return standardized.path
            }
            return String(standardized.path.dropFirst(projectURL.path.count + 1))
        }
    }
#endif
