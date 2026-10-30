import Foundation

struct EditorCloudAgentTool: Sendable {
    var name: String
    var definition: EditorCloudValue
    var readOnly: Bool
    var invoke: @Sendable (EditorCloudValue) async throws -> String
}

/// The native tool loop uses the same server wallet and model as browser Studio.
actor EditorCloudAgentService: EditorAgentServicing {
    typealias TransportFactory = @Sendable () async throws -> EditorCloudAITransport
    typealias ToolsFactory = @Sendable (URL) async throws -> [EditorCloudAgentTool]
    private let transportFactory: TransportFactory
    private let toolsFactory: ToolsFactory
    private var turns: [String: Task<EditorAgentRunResult, Error>] = [:]
    private var permissions: [String: (String, CheckedContinuation<Bool, Never>)] = [:]

    init(
        transportFactory: @escaping TransportFactory = { try await EditorCloudAccount.shared.hostedAIGenerator() },
        toolsFactory: @escaping ToolsFactory = { url in try await MainActor.run { try EditorCloudToolHost(projectURL: url).tools() } }
    ) {
        self.transportFactory = transportFactory
        self.toolsFactory = toolsFactory
    }
    func connect(
        _ request: EditorAgentRunRequest, onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void,
        onProjectFileChanged: @escaping @Sendable (String) async -> Void
    ) async throws -> EditorAgentSessionConfiguration {
        do { _ = try await transportFactory() } catch { throw await Self.localized(error) }
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
    private func run(
        _ request: EditorAgentRunRequest, onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void,
        onProjectFileChanged: @escaping @Sendable (String) async -> Void
    ) async throws -> EditorAgentRunResult {
        guard !request.attachments.contains(where: { $0.mimeType.hasPrefix("image/") }) else {
            throw EditorAgentServiceError.providerFailure("Coder Next supports text. Choose a vision model to send images.")
        }
        let transport = try await transportFactory()
        let planning = [.ask, .plan].contains(request.mode)
        let tools = try await toolsFactory(request.projectURL).filter { !planning || ($0.readOnly && EditorCloudToolHost.planTools.contains($0.name)) }
        guard tools.count <= 96, Set(tools.map(\.name)).count == tools.count else { throw EditorAIError.invalidResponse }
        var messages = request.session.events.compactMap { event -> EditorCloudValue? in
            guard let message = event.message, [.user, .assistant].contains(message.role) else { return nil }
            let text = message.segments.compactMap(\.text).joined(separator: "\n")
            let references = EditorAgentSceneAnnotation.referenceBlock(message.sceneAnnotations ?? [])
            return ["role": .string(message.role.rawValue), "content": .string(text + (references.isEmpty ? "" : "\n\n" + references))]
        }
        if messages.last?["role"].string == "user" { messages.removeLast() }
        messages.append(["role": "user", "content": .string(EditorAgentPromptContext.text(for: request))])
        for _ in 0..<40 {
            try Task.checkCancellation()
            while messages.count > 2, try JSONEncoder().encode(messages).count > 90_000 {
                messages.removeFirst()
                while messages.first?["role"].string == "tool" { messages.removeFirst() }
            }
            let input: EditorCloudValue = [
                "operationID": .string(UUID().uuidString), "providerID": "openrouter", "model": "qwen/qwen3-coder-next",
                "billingMode": "ada", "mode": planning ? "plan" : "build", "tools": .array(tools.map(\.definition)),
                "messages": .array(messages + [["role": "user", "content": .string("Current request: " + String(request.prompt.prefix(4000)))]]),
            ]
            guard try JSONEncoder().encode(input).count <= 180_000 else {
                throw EditorAgentServiceError.providerFailure("The AI context is too large. Start a new conversation to continue.")
            }
            let response = Reply()
            let messageID = UUID().uuidString
            try await transport(input) { event in
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
                await onEvent(toolEvent)
                let output: String
                do {
                    guard let tool = tools.first(where: { $0.name == name }), let raw = call["function"]["arguments"].string,
                        case .object(let arguments) = try JSONDecoder().decode(EditorCloudValue.self, from: Data(raw.utf8))
                    else { throw EditorAIError.invalidResponse }
                    if !tool.readOnly {
                        let details: [String] = [name, request.project.project.name ?? request.projectURL.lastPathComponent,
                            arguments["path"]?.string ?? arguments["destination"]?.string ?? ""]
                        let permissionSummary = details.joined(separator: "\n")
                        guard request.project.ai.agent.permissionMode != .deny,
                            await permission(session: request.session.id, toolID: id, name: permissionSummary, onEvent: onEvent)
                        else {
                            throw EditorAgentServiceError.providerFailure("The user declined this project change.")
                        }
                    }
                    try Task.checkCancellation()
                    output = try await tool.invoke(.object(arguments))
                    toolEvent.toolCall?.status = .completed
                    if !tool.readOnly, let path = arguments["path"]?.string ?? (name == "editor_web_download" ? arguments["destination"]?.string : nil) {
                        await onProjectFileChanged(path)
                    }
                } catch is CancellationError { throw CancellationError() } catch {
                    output = "Tool failed: " + error.localizedDescription
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
        session: String, toolID: String, name: String,
        onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void
    ) async -> Bool {
        let id = UUID().uuidString
        let event = EditorAgentEvent(
            kind: .permission,
            permission: .init(
                id: id, summary: name, toolCallID: toolID,
                options: [.init(id: "allow", name: "Allow once", kind: "allow_once"), .init(id: "deny", name: "Reject", kind: "reject_once")], state: .pending, selectedOptionID: nil))
        return await withCheckedContinuation { continuation in
            permissions[id] = (session, continuation)
            Task { await onEvent(event) }
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
