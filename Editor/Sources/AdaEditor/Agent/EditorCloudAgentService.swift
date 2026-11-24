import Foundation

struct EditorCloudAgentTool: Sendable {
    var name: String
    var definition: EditorCloudValue
    var readOnly: Bool
    var invoke: @Sendable (EditorCloudValue) async throws -> String
    var validate: (@Sendable (EditorCloudValue) throws -> Void)? = nil
    var approvalTarget: (@Sendable (EditorCloudValue) -> String?)? = nil
    var approvalDetails: (@Sendable (EditorCloudValue) throws -> String?)? = nil
}

/// The native tool loop uses the same server wallet and model as browser Studio.
actor EditorCloudAgentService: EditorAgentServicing {
    typealias ConnectionFactory = @Sendable () async throws -> EditorCloudAIConnection
    typealias ToolsFactory = @Sendable (URL) async throws -> [EditorCloudAgentTool]
    private let host: EditorCloudToolCatalog.Host
    private let connectionFactory: ConnectionFactory
    private let toolsFactory: ToolsFactory
    private var turns: [String: Task<EditorAgentRunResult, Error>] = [:]
    private var permissions: [String: (String, CheckedContinuation<Bool, Never>)] = [:]

    init(
        host: EditorCloudToolCatalog.Host = .desktop,
        connectionFactory: @escaping ConnectionFactory = { try await EditorCloudAccount.shared.hostedAIGenerator() },
        toolsFactory: @escaping ToolsFactory = { url in try await MainActor.run { try EditorCloudAgentService.defaultTools(projectURL: url) } }
    ) {
        self.host = host
        self.connectionFactory = connectionFactory
        self.toolsFactory = toolsFactory
    }

    init(transportFactory: @escaping @Sendable () async throws -> EditorCloudAITransport, toolsFactory: @escaping ToolsFactory) {
        self.init(connectionFactory: { EditorCloudAIConnection(toolContract: nil, generate: try await transportFactory()) }, toolsFactory: toolsFactory)
    }

    func connect(
        _ request: EditorAgentRunRequest, onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void,
        onProjectFileChanged: @escaping @Sendable (String) async -> Void
    ) async throws -> EditorAgentSessionConfiguration {
        do { _ = try await connectionFactory() } catch { throw await Self.localized(error) }
        return .init(agentName: "Ada AI · Coder Next", selectors: [])
    }
    func send(
        _ request: EditorAgentRunRequest, onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void,
        onProjectFileChanged: @escaping @Sendable (String) async -> Void
    ) async throws -> EditorAgentRunResult {
        guard turns[request.session.id] == nil else { throw EditorAgentServiceError.sessionUnavailable }
        let task = Task { try await run(request, onEvent: onEvent, onProjectFileChanged: onProjectFileChanged) }
        turns[request.session.id] = task
        defer { turns.removeValue(forKey: request.session.id) }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { await self.cancel(sessionID: request.session.id) }
            }
        } catch is CancellationError { throw CancellationError() } catch {
            if task.isCancelled || Task.isCancelled { throw CancellationError() }
            throw await Self.localized(error)
        }
    }
    private static func localized(_ error: any Error) async -> EditorAgentServiceError {
        let key = error.localizedDescription
        return .providerFailure(await MainActor.run { L10n.tr(key) })
    }

    @MainActor private static func defaultTools(projectURL: URL) throws -> [EditorCloudAgentTool] {
        let native = try EditorCloudToolHost(projectURL: projectURL).tools()
        #if os(macOS) || os(Windows)
        let root = projectURL.resolvingSymlinksInPath().standardizedFileURL
        let workspaceGeneration = EditorAgentMCPTools.shared.workspaceGeneration
        let isCurrentProject: @Sendable () async -> Bool = {
            await EditorAgentMCPTools.shared.isCurrentWorkspace(root, generation: workspaceGeneration)
        }
        let mayInvoke: @Sendable () async -> Bool = {
            await EditorAgentMCPTools.shared.allowsExternalInvocations
        }
        #if os(Windows)
        let preset = EditorBlenderMCPSettings.shared.tools(projectURL: root, isCurrentProject: isCurrentProject, mayInvoke: mayInvoke)
        #else
        let preset: [EditorCloudAgentTool] = []
        #endif
        return native + EditorLocalMCPSettings.shared.cloudTools(preset: preset, isCurrentProject: isCurrentProject, mayInvoke: mayInvoke)
        #else
        return native
        #endif
    }
    private func run(
        _ request: EditorAgentRunRequest, onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void,
        onProjectFileChanged: @escaping @Sendable (String) async -> Void
    ) async throws -> EditorAgentRunResult {
        guard !request.attachments.contains(where: { $0.mimeType.hasPrefix("image/") }) else {
            throw EditorAgentServiceError.providerFailure("Coder Next supports text. Choose a vision model to send images.")
        }
        let connection = try await connectionFactory()
        let planning = [.ask, .plan].contains(request.mode)
        let availableTools = try await toolsFactory(request.projectURL)
        let hasExternalTools = host == .desktop && availableTools.contains { $0.name.hasPrefix("editor_external_") }
        let baseVersion = EditorCloudToolCatalog.currentVersion
        let externalVersion = EditorCloudToolCatalog.externalVersion
        let version: Int?
        if host == .desktop, connection.toolContract == Int64(externalVersion) || (hasExternalTools && connection.supportsExternalTools) {
            version = externalVersion
        } else {
            version = connection.toolContract == Int64(baseVersion) ? baseVersion : nil
        }
        let selection = try version.map {
            try EditorCloudToolCatalog.load(version: $0, hasExternalTools: hasExternalTools).selection(host: host, planning: planning)
        }
        let tools = availableTools.filter {
            if $0.name.hasPrefix("editor_external_") { return version == externalVersion && hasExternalTools }
            if selection != nil {
                return true
            }
            return $0.name == $0.name.lowercased() && (!planning || ($0.readOnly && EditorCloudToolHost.planTools.contains($0.name)))
        }
        guard Set(tools.map(\.name)).count == tools.count else { throw EditorAIError.invalidResponse }
        let bindings = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        let definitions = selection?.definitions ?? tools.map(\.definition)
        guard definitions.count <= 96 else { throw EditorAIError.invalidResponse }
        var messages = request.session.events.compactMap { event -> EditorCloudValue? in
            guard let message = event.message, [.user, .assistant].contains(message.role) else { return nil }
            let text = message.segments.compactMap(\.text).joined(separator: "\n")
            let references = EditorAgentSceneAnnotation.referenceBlock(message.sceneAnnotations ?? [])
            return ["role": .string(message.role.rawValue), "content": .string(text + (references.isEmpty ? "" : "\n\n" + references))]
        }
        if messages.last?["role"].string == "user" { messages.removeLast() }
        let prompt = EditorAgentPromptContext.text(for: request)
        messages.append(["role": "user", "content": .string(selection.map { $0.guidance + "\n\n" + prompt } ?? prompt)])
        for _ in 0..<40 {
            try Task.checkCancellation()
            while messages.count > 2, try JSONEncoder().encode(messages).count > 90_000 {
                messages.removeFirst()
                while messages.first?["role"].string == "tool" { messages.removeFirst() }
            }
            var input: EditorCloudValue = [
                "operationID": .string(UUID().uuidString), "providerID": "openrouter", "model": "qwen/qwen3-coder-next",
                "billingMode": "ada", "mode": planning ? "plan" : "build", "tools": .array(definitions),
                "messages": .array(messages + [["role": "user", "content": .string("Current request: " + String(request.prompt.prefix(4000)))]]),
            ]
            if let version {
                input["toolContract"] = .integer(Int64(version))
                input["toolHost"] = .string(host.rawValue)
            }
            guard try JSONEncoder().encode(input).count <= 180_000 else {
                throw EditorAgentServiceError.providerFailure("The AI context is too large. Start a new conversation to continue.")
            }
            let response = Reply()
            let messageID = UUID().uuidString
            try await connection.generate(input) { event in
                try Task.checkCancellation()
                if let text = try await response.receive(event) {
                    await onEvent(.init(id: messageID, kind: .message, message: .init(role: .assistant, segments: [.init(kind: .text, text: text)])))
                }
            }
            try Task.checkCancellation()
            let (text, calls) = try await response.result()
            if calls.isEmpty {
                return .init(
                    upstreamSessionID: request.session.id, assistantText: text, stopReason: "end_turn",
                    configuration: .init(agentName: "Ada AI · Coder Next", selectors: []))
            }
            messages.append(["role": "assistant", "content": .string(text), "toolCalls": .array(calls)])
            for call in calls {
                try Task.checkCancellation()
                let id = call["id"].string ?? ""
                let name = call["function"]["name"].string ?? ""
                var toolEvent = EditorAgentEvent(
                    id: id, kind: .toolCall,
                    toolCall: .init(id: id, title: name.replacingOccurrences(of: "_", with: "."), kind: "tool", status: .inProgress, content: [], locations: []))
                let output: String
                do {
                    guard let raw = call["function"]["arguments"].string,
                        case let .object(arguments) = try JSONDecoder().decode(EditorCloudValue.self, from: Data(raw.utf8))
                    else { throw EditorAIError.invalidResponse }
                    let action = try selection?.resolve(name: name, input: .object(arguments))
                    guard let tool = bindings[action?.legacyName ?? name] else {
                        throw EditorAIError.invalidResponse
                    }
                    let resolvedArguments = try action?.legacyArguments() ?? .object(arguments)
                    try tool.validate?(resolvedArguments)
                    let needsApproval = action?.approval ?? !tool.readOnly
                    let target = tool.approvalTarget?(resolvedArguments) ?? action?.target ?? arguments["path"]?.string ?? arguments["destination"]?.string
                    if let action {
                        toolEvent.toolCall?.title = [action.key, target].compactMap { $0 }.joined(separator: " ")
                    }
                    await onEvent(toolEvent)
                    try Task.checkCancellation()
                    if needsApproval {
                        let details = [action?.key ?? name, request.project.project.name ?? request.projectURL.lastPathComponent, target ?? ""]
                        let permissionSummary = details.joined(separator: "\n")
                        let inputDetails = try tool.approvalDetails?(resolvedArguments)
                        guard request.project.ai.agent.permissionMode != .deny,
                            await permission(session: request.session.id, toolID: id, name: permissionSummary, inputDetails: inputDetails, onEvent: onEvent)
                        else {
                            throw EditorAgentServiceError.providerFailure("The user declined this project change.")
                        }
                    }
                    try Task.checkCancellation()
                    let result = try await tool.invoke(resolvedArguments)
                    output = try action?.result(result, host: host) ?? result
                    toolEvent.toolCall?.status = .completed
                    let changedPath: String?
                    if action?.key == "editor_external/invoke" {
                        let external = resolvedArguments["tool"].string?.hasPrefix("blender.") == true
                            ? try? JSONDecoder().decode(EditorCloudValue.self, from: Data(result.utf8)) : nil
                        changedPath = external?["artifact"].string ?? external?["assetPath"].string
                    } else {
                        changedPath = action?.target ?? arguments["path"]?.string ?? (name == "editor_web_download" ? arguments["destination"]?.string : nil)
                    }
                    if needsApproval, let path = changedPath {
                        await onProjectFileChanged(path)
                    }
                } catch is CancellationError { throw CancellationError() } catch {
                    let details = error.localizedDescription
                    let message = name == "editor_external" ? await MainActor.run { L10n.tr(details) } : details
                    output = "Tool failed: " + message
                    toolEvent.toolCall?.status = .failed
                }
                toolEvent.toolCall?.content = [.init(kind: .text, text: String(output.prefix(32_000)))]
                await onEvent(toolEvent)
                messages.append(["role": "tool", "toolCallID": .string(id), "content": .string(String(output.prefix(32_000)))])
            }
        }
        throw EditorAgentServiceError.providerFailure("The agent reached its step limit. Continue from the saved project.")
    }
    private func permission(
        session: String, toolID: String, name: String, inputDetails: String?,
        onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void
    ) async -> Bool {
        let id = UUID().uuidString
        let event = EditorAgentEvent(
            kind: .permission,
            permission: .init(
                id: id, summary: name, toolCallID: toolID,
                options: [.init(id: "allow", name: "Allow once", kind: "allow_once"), .init(id: "deny", name: "Reject", kind: "reject_once")],
                state: .pending, selectedOptionID: nil, inputDetails: inputDetails))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                permissions[id] = (session, continuation)
                Task { await onEvent(event) }
            }
        } onCancel: {
            Task { await self.resolvePermission(requestID: id, optionID: nil) }
        }
    }
    func resolvePermission(requestID: String, optionID: String?) async {
        permissions.removeValue(forKey: requestID)?.1.resume(returning: optionID == "allow")
    }
    func setConfiguration(sessionID: String, selectorID: String, valueID: String) async throws -> EditorAgentSessionConfiguration {
        .init(agentName: "Ada AI · Coder Next", selectors: [])
    }
    func cancel(sessionID: String) async {
        turns[sessionID]?.cancel()
        for id in permissions.keys.filter({ permissions[$0]?.0 == sessionID }) { await resolvePermission(requestID: id, optionID: nil) }
    }
    func shutdown() async { for id in Array(turns.keys) { await cancel(sessionID: id) } }

    private actor Reply {
        var text = "", calls: [EditorCloudValue] = [], complete = false
        func receive(_ event: EditorCloudValue) throws -> String? {
            switch event["type"].string {
            case "text":
                text += event["text"].string ?? ""
                guard text.utf8.count <= 512 * 1024 else { throw EditorAIError.invalidResponse }
                return text
            case "tool":
                guard calls.count < 32 else { throw EditorAIError.invalidResponse }
                calls.append(event["call"])
            case "complete": complete = true
            case "usage": break
            default: throw EditorAIError.invalidResponse
            }
            return nil
        }
        func result() throws -> (String, [EditorCloudValue]) {
            let ids = calls.compactMap { $0["id"].string }
            guard complete, ids.count == calls.count, Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }) else { throw EditorAIError.invalidResponse }
            return (text, calls)
        }
    }
}
