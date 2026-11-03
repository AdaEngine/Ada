#if os(Windows)
import ACPModel
import Foundation

enum DebugMessageDirection: Sendable { case outgoing, incoming }

struct DebugMessage: Sendable {
    let direction: DebugMessageDirection
    let rawData: Data
}

/// Windows uses the upstream ACP model and the editor's existing session/UI logic.
/// Only subprocess ownership and the JSON-RPC stdio router are platform-specific.
actor Client {
    private var process: EditorWindowsProcess?
    private var writer: EditorWindowsACPWriter?
    private var supervisor: Task<Void, Never>?
    private var pending: [RequestId: CheckedContinuation<JSONRPCResponse, any Error>] = [:]
    private var deadlines: [RequestId: Task<Void, Never>] = [:]
    private var callbacks: [RequestId: Task<Void, Never>] = [:]
    private var nextID = 0
    private var promptRequests = Set<RequestId>()
    private var cancellationTasks: [SessionId: Task<Void, Never>] = [:]
    private var buffer = Data()
    private var diagnostics = Data()
    private var isClosing = false
    private weak var delegate: (any ClientDelegate)?
    var clientDelegate: (any ClientDelegate)? { delegate }
    private let notificationPair = AsyncStream<JSONRPCNotification>.makeStream()
    private var debugPair: (stream: AsyncStream<DebugMessage>, continuation: AsyncStream<DebugMessage>.Continuation)?

    var notifications: AsyncStream<JSONRPCNotification> { notificationPair.stream }
    var isRunning: Bool { !isClosing && process?.isRunning == true }
    var debugMessages: AsyncStream<DebugMessage>? { debugPair?.stream }
    func enableDebugStream() { if debugPair == nil { debugPair = AsyncStream.makeStream() } }
    func setDelegate(_ delegate: any ClientDelegate) { self.delegate = delegate }

    func launch(agentPath: String, arguments: [String] = [], workingDirectory: String? = nil, environment: [String: String]? = nil) async throws {
        guard process == nil else { throw ClientError.transportError("Agent already started.") }
        let environment = EditorWindowsAgentCommand.environment(environment ?? [:])
        let invocation = try EditorWindowsAgentCommand.resolve(agentPath, arguments: arguments, environment: environment)
        let child = try EditorWindowsProcess(executable: invocation.executable, arguments: invocation.arguments,
            directory: workingDirectory.map { URL(fileURLWithPath: $0) }, environment: environment)
        process = child
        writer = EditorWindowsACPWriter(child.input)
        let outputChunks = EditorWindowsACPTransport.chunks(child.output)
        let errorChunks = EditorWindowsACPTransport.chunks(child.error)
        // These owned tasks are joined after process termination so trailing updates
        // cannot be lost when a short-lived adapter exits immediately after replying.
        supervisor = Task {
            async let stdout: Void = consume(outputChunks)
            async let stderr: Void = consumeDiagnostics(errorChunks)
            var code: Int32 = 0
            for await status in child.exit { code = status }
            child.terminate()
            _ = await (stdout, stderr)
            await ended(code: code)
        }
    }

    func initialize(capabilities: ClientCapabilities, clientInfo: ClientInfo = ClientInfo(name: "AdaEditor", version: "1.0.0"), timeout: TimeInterval = 30) async throws -> InitializeResponse {
        try await request("initialize", InitializeRequest(protocolVersion: 1, clientCapabilities: capabilities, clientInfo: clientInfo), timeout: timeout)
    }

    func newSession(workingDirectory: String, mcpServers: [MCPServerConfig], timeout: TimeInterval = 30) async throws -> NewSessionResponse {
        try await request("session/new", NewSessionRequest(cwd: workingDirectory, mcpServers: mcpServers), timeout: timeout)
    }

    func loadSession(sessionId: SessionId, cwd: String?, mcpServers: [MCPServerConfig]) async throws -> LoadSessionResponse {
        struct Payload: Decodable, Sendable {
            var sessionId: SessionId?
            var modes: ModesInfo?
            var models: ModelsInfo?
            var configOptions: [SessionConfigOption]?
        }
        let result: Payload = try await request("session/load", LoadSessionRequest(sessionId: sessionId, cwd: cwd, mcpServers: mcpServers))
        return LoadSessionResponse(sessionId: result.sessionId ?? sessionId, modes: result.modes, models: result.models, configOptions: result.configOptions)
    }

    func sendPrompt(sessionId: SessionId, content: [ContentBlock]) async throws -> SessionPromptResponse {
        try await request("session/prompt", SessionPromptRequest(sessionId: sessionId, prompt: content), timeout: nil)
    }

    func setMode(sessionId: SessionId, modeId: String) async throws -> SetModeResponse {
        let _: AnyCodable = try await request("session/set_mode", SetModeRequest(sessionId: sessionId, modeId: modeId))
        return SetModeResponse(success: true)
    }

    func setModel(sessionId: SessionId, modelId: String) async throws -> SetModelResponse {
        let _: AnyCodable = try await request("session/set_model", SetModelRequest(sessionId: sessionId, modelId: modelId))
        return SetModelResponse(success: true)
    }

    func setConfigOption(sessionId: SessionId, configId: SessionConfigId, value: SessionConfigValueId) async throws -> SetSessionConfigOptionResponse {
        try await request("session/set_config_option", SetSessionConfigOptionRequest(sessionId: sessionId, configId: configId, value: .select(value)))
    }

    func cancelSession(sessionId: SessionId) async throws {
        let active = promptRequests
        try await send(JSONRPCNotification(method: "session/cancel", params: AnyCodable(["sessionId": sessionId.value])))
        cancellationTasks[sessionId]?.cancel()
        cancellationTasks[sessionId] = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !active.isDisjoint(with: promptRequests) else { return }
            isClosing = true
            for id in active { fail(id, error: CancellationError()) }
            process?.terminate()
        }
    }

    func terminate() async {
        isClosing = true
        process?.terminate()
        await writer?.close()
        await supervisor?.value
        await ended(code: 0)
    }

    private func request<Parameters: Encodable & Sendable, Response: Decodable & Sendable>(
        _ method: String, _ parameters: Parameters, timeout: TimeInterval? = 30
    ) async throws -> Response {
        try Task.checkCancellation()
        guard isRunning else { throw ClientError.processNotRunning }
        nextID += 1
        let id = RequestId.number(nextID)
        let params = try JSONDecoder().decode(AnyCodable.self, from: JSONEncoder().encode(parameters))
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONRPCResponse, any Error>) in
                pending[id] = continuation
                if method == "session/prompt" { promptRequests.insert(id) }
                if let timeout {
                    deadlines[id] = Task {
                        do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                        fail(id, error: ClientError.requestTimeout)
                    }
                }
                Task {
                    do { try await send(JSONRPCRequest(id: id, method: method, params: params)) }
                    catch { fail(id, error: error) }
                }
            }
        } onCancel: { Task { await self.fail(id, error: CancellationError()) } }
        if let error = response.error { throw ClientError.agentError(error) }
        guard let result = response.result else { throw ClientError.invalidResponse }
        return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(result))
    }

    private func send(_ message: some Encodable) async throws {
        guard let writer else { throw ClientError.processNotRunning }
        let data = try JSONEncoder().encode(message)
        guard data.count <= EditorWindowsACPTransport.maximumMessageBytes else { throw ClientError.transportError("ACP message exceeds 16 MiB.") }
        debugPair?.continuation.yield(DebugMessage(direction: .outgoing, rawData: data))
        try await writer.write(data + Data([10]))
    }

    private func consume(_ chunks: AsyncThrowingStream<Data, any Error>) async {
        do {
            for try await data in chunks {
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if line.isEmpty { continue }
                    guard line.count <= EditorWindowsACPTransport.maximumMessageBytes,
                        let message = try? JSONDecoder().decode(ACPModel.Message.self, from: line) else {
                        await failed(ClientError.transportError("Agent stdout contained an invalid or oversized ACP message."))
                        return
                    }
                    debugPair?.continuation.yield(DebugMessage(direction: .incoming, rawData: line))
                    receive(message)
                }
                if buffer.count > EditorWindowsACPTransport.maximumMessageBytes {
                    await failed(ClientError.transportError("ACP message exceeds 16 MiB."))
                    return
                }
            }
        } catch {
            await failed(error)
        }
    }

    private func consumeDiagnostics(_ chunks: AsyncThrowingStream<Data, any Error>) async {
        do {
            for try await data in chunks {
                diagnostics.append(data)
                if diagnostics.count > 4096 { diagnostics.removeFirst(diagnostics.count - 4096) }
            }
        } catch {
            await failed(error)
        }
    }

    private func receive(_ message: ACPModel.Message) {
        switch message {
        case let .response(response):
            promptRequests.remove(response.id)
            deadlines.removeValue(forKey: response.id)?.cancel()
            pending.removeValue(forKey: response.id)?.resume(returning: response)
        case let .notification(notification): notificationPair.continuation.yield(notification)
        case let .request(request):
            guard callbacks.count < 128, callbacks[request.id] == nil else {
                Task { try? await send(JSONRPCResponse(id: request.id, result: nil, error: JSONRPCError(code: -32000, message: "Too many agent requests.", data: nil))) }
                return
            }
            callbacks[request.id] = Task {
                let response: JSONRPCResponse
                do { response = JSONRPCResponse(id: request.id, result: try await route(request), error: nil) }
                catch { response = JSONRPCResponse(id: request.id, result: nil, error: JSONRPCError(code: -32603, message: error.localizedDescription, data: nil)) }
                try? await send(response)
                callbacks.removeValue(forKey: request.id)
            }
        }
    }

    private func fail(_ id: RequestId, error: any Error) {
        promptRequests.remove(id)
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failed(_ error: any Error) async {
        isClosing = true
        for id in Array(pending.keys) { fail(id, error: error) }
        process?.terminate()
    }

    private func ended(code: Int32) async {
        let details = String(decoding: diagnostics, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let error = ClientError.transportError("Agent exited (\(code))." + (details.isEmpty ? "" : " \(details)"))
        for id in Array(pending.keys) { fail(id, error: error) }
        for task in callbacks.values { task.cancel() }
        callbacks.removeAll()
        for task in cancellationTasks.values { task.cancel() }
        cancellationTasks.removeAll()
        notificationPair.continuation.finish()
        debugPair?.continuation.finish()
        await delegate?.shutdown()
        await writer?.close()
        writer = nil
        process = nil
    }
}
#endif
