#if os(macOS) || os(Windows)
import Foundation

#if os(Windows)
import WinSDK

typealias EditorWindowsLocalMCP = EditorLocalMCPConnection
private typealias EditorLocalMCPProcess = EditorWindowsProcess
private typealias EditorLocalMCPWriter = EditorWindowsACPWriter
private typealias EditorLocalMCPPipe = EditorWindowsACPTransport
#endif

/// MCP stdio lines use JSON-RPC framing independent of the Studio ACP bridge.
actor EditorLocalMCPConnection {
    private static let protocolVersion = "2025-11-25"
    private static let supportedProtocols = [protocolVersion, "2025-06-18", "2025-03-26", "2024-11-05"]
    private static let maximumLineBytes = 1_048_576
    private let child: EditorLocalMCPProcess
    private let writer: EditorLocalMCPWriter
    private let termination = AsyncStream<Void>.makeStream()
    private let changes = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
    nonisolated var toolChanges: AsyncStream<UInt64> { changes.stream }
    private(set) var serverIdentity: EditorCloudValue = [:]
    private var reader: Task<Void, Never>?
    private var stderr: Task<Void, Never>?
    private var pending: CheckedContinuation<EditorCloudValue, any Error>?
    private var nextID: Int64 = 0
    private var isClosed = false
    private(set) var toolListRevision: UInt64 = 0

    init(executable: URL, arguments: [String], directory: URL) throws {
        #if os(Windows)
        let allowed = Set(["systemroot", "windir", "systemdrive", "path", "pathext", "userprofile", "appdata", "localappdata", "temp", "tmp"])
        #else
        let allowed = Set(["home", "path", "tmpdir", "lang", "lc_all", "lc_ctype", "user", "logname"])
        #endif
        var environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key.lowercased()) }
        // MCP stdio is UTF-8. Python otherwise uses the legacy code page for redirected streams on Windows.
        environment["PYTHONIOENCODING"] = "utf-8"
        do {
            child = try EditorLocalMCPProcess(executable: executable, arguments: arguments, directory: directory, environment: environment)
        } catch {
            throw Failure.launch
        }
        writer = EditorLocalMCPWriter(child.input)
    }

    deinit {
        child.terminate()
        reader?.cancel()
        stderr?.cancel()
    }

    func initialize() async throws {
        guard reader == nil, !isClosed else { throw Failure.closed }
        let output = EditorLocalMCPPipe.chunks(child.output)
        let diagnostics = EditorLocalMCPPipe.chunks(child.error)
        reader = Task { [weak self] in
            do {
                var buffer = Data()
                for try await chunk in output {
                    buffer.append(chunk)
                    while let delimiter = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<delimiter])
                        buffer.removeSubrange(...delimiter)
                        try await self?.receive(line)
                    }
                    guard buffer.count <= Self.maximumLineBytes else { throw Failure.invalidResponse }
                }
                await self?.close(.closed)
            } catch {
                await self?.close(.invalidResponse)
            }
        }
        stderr = Task {
            do { for try await _ in diagnostics {} } catch { /* Diagnostics stay local. */ }
        }
        let params: EditorCloudValue = [
            "protocolVersion": .string(Self.protocolVersion), "clientInfo": ["name": "Ada Studio", "version": "1"], "capabilities": [:]
        ]
        let reply = try await request("initialize", params: params, timeout: .seconds(10))
        guard let version = reply["protocolVersion"].string, Self.supportedProtocols.contains(version), case .object = reply["capabilities"]["tools"] else {
            close(.unsupported)
            throw Failure.unsupported
        }
        serverIdentity = [
            "protocol": .string(version),
            "name": .string(EditorLocalMCPTool.clean(reply["serverInfo"]["name"].string ?? "", limit: 128, multiline: false)),
            "version": .string(EditorLocalMCPTool.clean(reply["serverInfo"]["version"].string ?? "", limit: 128, multiline: false))
        ]
        try await send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    func tools(expectedRevision: UInt64? = nil) async throws -> [EditorCloudValue] {
        var tools: [EditorCloudValue] = []
        var cursor: String?
        var cursors: Set<String> = []
        for _ in 0..<16 {
            let params: EditorCloudValue = cursor.map { ["cursor": .string($0)] } ?? [:]
            let reply = try await request("tools/list", params: params, timeout: .seconds(10), expectedRevision: expectedRevision)
            guard case let .array(page) = reply["tools"], tools.count + page.count <= 512 else { throw Failure.invalidResponse }
            tools += page
            if reply["nextCursor"] == .null {
                if let expectedRevision, expectedRevision != toolListRevision { throw Failure.unsupported }
                return tools
            }
            guard let next = reply["nextCursor"].string, cursors.insert(next).inserted else { throw Failure.invalidResponse }
            cursor = next
        }
        throw Failure.invalidResponse
    }

    func call(
        _ name: String,
        arguments: EditorCloudValue,
        expectedRevision: UInt64? = nil,
        authorize: (@Sendable () async -> Bool)? = nil
    ) async throws -> EditorCloudValue {
        let reply = try await request(
            "tools/call",
            params: ["name": .string(name), "arguments": arguments],
            timeout: .seconds(60),
            expectedRevision: expectedRevision,
            authorize: authorize
        )
        guard reply["isError"].bool != true else { throw Failure.tool }
        return reply
    }

    nonisolated static func removeEmptyDirectory(_ directory: URL) {
        #if os(Windows)
        _ = RemoveDirectoryW(Array(directory.path.utf16) + [0])
        #else
        EditorLocalMCPProcess.removeEmptyDirectory(directory)
        #endif
    }

    func disconnect() { close(.closed) }

    #if os(macOS)
    nonisolated func terminateProcess() { child.terminate() }
    #endif

    func waitForClose() async {
        for await _ in termination.stream {}
    }

    private func request(
        _ method: String,
        params: EditorCloudValue,
        timeout: Duration,
        expectedRevision: UInt64? = nil,
        authorize: (@Sendable () async -> Bool)? = nil
    ) async throws -> EditorCloudValue {
        try Task.checkCancellation()
        guard !isClosed else { throw Failure.closed }
        guard pending == nil else { throw Failure.busy }
        nextID += 1
        let id = nextID
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.expire(id)
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                Task {
                    let isAuthorized = await authorize?() ?? true
                    guard id == nextID, let current = pending else {
                        return
                    }
                    guard isAuthorized else {
                        pending = nil
                        current.resume(throwing: Failure.authorization)
                        return
                    }
                    if let expectedRevision, expectedRevision != toolListRevision {
                        pending = nil
                        current.resume(throwing: Failure.unsupported)
                        return
                    }
                    do { try await send(["jsonrpc": "2.0", "id": .integer(id), "method": .string(method), "params": params]) } catch { close(.closed) }
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func send(_ value: EditorCloudValue) async throws {
        guard !isClosed else { throw Failure.closed }
        let data = try JSONEncoder().encode(value)
        guard data.count <= Self.maximumLineBytes else { throw Failure.invalidResponse }
        try await writer.write(data + Data([10]))
    }

    private func receive(_ line: Data) async throws {
        guard line.count <= Self.maximumLineBytes else { throw Failure.invalidResponse }
        let message = try JSONDecoder().decode(EditorCloudValue.self, from: line)
        guard message["jsonrpc"].string == "2.0" else { throw Failure.invalidResponse }
        if let method = message["method"].string {
            if message["id"] != .null {
                try await send(["jsonrpc": "2.0", "id": message["id"], "error": ["code": -32601, "message": "Method not supported"]])
            } else if method == "notifications/tools/list_changed" {
                toolListRevision &+= 1
                changes.continuation.yield(toolListRevision)
            }
            return
        }
        guard message["id"].int == nextID, let continuation = pending else {
            return
        }
        pending = nil
        if case .object = message["result"], message["error"] == .null {
            continuation.resume(returning: message["result"])
        } else {
            continuation.resume(throwing: Failure.tool)
        }
    }

    private func expire(_ id: Int64) {
        if id == nextID && pending != nil { close(.timeout) }
    }

    private func cancel(_ id: Int64) {
        if id == nextID { close(.closed, cancelling: true) }
    }

    private func close(_ error: Failure, cancelling: Bool = false) {
        guard !isClosed else {
            return
        }
        isClosed = true
        child.terminate()
        termination.continuation.finish()
        changes.continuation.finish()
        reader?.cancel()
        stderr?.cancel()
        let continuation = pending
        pending = nil
        if cancelling { continuation?.resume(throwing: CancellationError()) } else { continuation?.resume(throwing: error) }
    }

    enum Failure: LocalizedError {
        case launch, closed, invalidResponse, unsupported, tool, busy, timeout, authorization

        var errorDescription: String? {
            switch self {
            case .launch: "Could not start the Blender MCP executable. Check its path and try again."
            case .closed: "The Blender MCP connection closed. Reconnect in Agent Settings."
            case .invalidResponse: "Blender MCP returned an invalid or oversized response."
            case .unsupported: "This Blender MCP version is incompatible with Studio."
            case .tool: "Blender MCP could not complete the request. Check that Blender and its MCP add-on are running."
            case .busy: "Blender MCP is finishing another request."
            case .timeout: "Blender MCP timed out. Check Blender before retrying."
            case .authorization: "This local MCP tool is no longer available. Review the connection and try again."
            }
        }
    }
}
#endif
