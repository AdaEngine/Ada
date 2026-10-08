import Foundation

#if os(macOS)
/// Owns one LLDB adapter process. Protocol input, requests and cancellation are actor isolated.
public actor LLDBDebugClient {
    public nonisolated let events: AsyncStream<DebugJSON>
    private let eventContinuation: AsyncStream<DebugJSON>.Continuation
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var reader: Task<Void, Never>?
    private var errorReader: Task<Void, Never>?
    private var sequence = 0
    private var framer = DebugMessageFramer()
    private var pending: [Int: CheckedContinuation<DebugJSON, any Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]

    public init() {
        let stream = AsyncStream<DebugJSON>.makeStream()
        events = stream.stream
        eventContinuation = stream.continuation
    }

    public func start(executable: URL) throws {
        guard process == nil else { throw DebuggerError.requestFailed("Debugger already started.") }
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        child.executableURL = executable
        child.arguments = ["--repl-mode", "command"]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        let chunks = Self.chunks(from: stdout.fileHandleForReading)
        let errorChunks = Self.chunks(from: stderr.fileHandleForReading)
        do { try child.run() } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errors = stderr.fileHandleForReading
        reader = Task { [weak self] in
            for await chunk in chunks {
                guard !Task.isCancelled else { break }
                await self?.receive(chunk)
            }
            await self?.endOfInput()
        }
        errorReader = Task { [weak self] in
            for await chunk in errorChunks {
                guard !Task.isCancelled else { break }
                await self?.adapterOutput(chunk)
            }
        }
    }

    public func request(_ command: String, arguments: [String: DebugJSON] = [:], timeout: Duration = .seconds(30)) async throws -> DebugJSON {
        guard input != nil else { throw DebuggerError.disconnected }
        try Task.checkCancellation()
        sequence += 1
        let identifier = sequence
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[identifier] = continuation
                do {
                    try send(.object([
                        "seq": .integer(identifier), "type": .string("request"),
                        "command": .string(command), "arguments": .object(arguments)
                    ]))
                    timeouts[identifier] = Task { [weak self] in
                        do { try await Task.sleep(for: timeout) } catch { return }
                        await self?.fail(identifier, error: DebuggerError.timeout(command))
                    }
                } catch { fail(identifier, error: error) }
            }
        } onCancel: {
            Task { await self.fail(identifier, error: CancellationError()) }
        }
    }

    /// Gracefully terminates the owned debuggee before shutting down the adapter.
    public func disconnect() async {
        if input != nil {
            _ = try? await request("disconnect", arguments: ["terminateDebuggee": .bool(true)], timeout: .seconds(3))
        }
        close()
    }

    public func close() {
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        try? errors?.close()
        input = nil
        output = nil
        errors = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        reader?.cancel()
        errorReader?.cancel()
        for identifier in Array(pending.keys) { fail(identifier, error: DebuggerError.disconnected) }
        eventContinuation.finish()
    }

    private func receive(_ data: Data) {
        do {
            for message in try framer.append(data) {
                switch message["type"].string {
                case "response":
                    guard let identifier = message["request_seq"].int, let continuation = pending.removeValue(forKey: identifier) else { continue }
                    timeouts.removeValue(forKey: identifier)?.cancel()
                    if message["success"].bool == true { continuation.resume(returning: message["body"]) }
                    else { continuation.resume(throwing: DebuggerError.requestFailed(message["message"].string ?? "Debugger request failed.")) }
                case "event": eventContinuation.yield(message)
                case "request":
                    sequence += 1
                    try send(.object([
                        "seq": .integer(sequence), "type": .string("response"), "success": .bool(false),
                        "request_seq": message["seq"], "command": message["command"],
                        "message": .string("AdaEditor does not support this reverse request.")
                    ]))
                default: throw DebuggerError.protocolViolation("Unknown DAP message type.")
                }
            }
        } catch {
            eventContinuation.yield(.object(["event": .string("adapterError"), "body": .object(["message": .string(error.localizedDescription)])]))
            close()
        }
    }

    private func send(_ message: DebugJSON) throws {
        guard let input else { throw DebuggerError.disconnected }
        try input.write(contentsOf: DebugMessageFramer.encode(message))
    }

    private func fail(_ identifier: Int, error: any Error) {
        timeouts.removeValue(forKey: identifier)?.cancel()
        pending.removeValue(forKey: identifier)?.resume(throwing: error)
    }

    private func endOfInput() {
        do { try framer.finish() } catch {
            eventContinuation.yield(.object(["event": .string("adapterError"), "body": .object(["message": .string(error.localizedDescription)])]))
        }
        close()
    }

    private func adapterOutput(_ data: Data) {
        eventContinuation.yield(.object([
            "event": .string("output"),
            "body": .object(["category": .string("stderr"), "output": .string(String(decoding: data, as: UTF8.self))])
        ]))
    }

    private nonisolated static func chunks(from handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { readable in
                // Read only currently available pipe bytes. read(upToCount:) may wait
                // for the requested count and deadlock the DAP request/response handshake.
                let data = readable.availableData
                if data.isEmpty {
                    readable.readabilityHandler = nil
                    continuation.finish()
                } else { continuation.yield(data) }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }
}
#endif
