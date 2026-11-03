#if os(Windows)
import ACPModel
import Foundation

actor TerminalDelegate {
    private struct Terminal {
        var session: String
        var process: EditorWindowsProcess
        var completion: Task<Int32, Never>
        var output = Data()
        var limit: Int
        var truncated = false
        var exitCode: Int32?
    }
    private var terminals: [TerminalId: Terminal] = [:]

    func handleTerminalCreate(command: String, sessionId: String, args: [String]?, cwd: String?, env: [EnvVariable]?, outputByteLimit: Int?) async throws -> CreateTerminalResponse {
        guard terminals.count < 32 else { throw ClientError.transportError("Too many active agent terminals.") }
        let environment = EditorWindowsAgentCommand.environment(Dictionary((env ?? []).map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last }))
        let invocation = try EditorWindowsAgentCommand.resolve(command, arguments: args ?? [], environment: environment)
        let process = try EditorWindowsProcess(executable: invocation.executable, arguments: invocation.arguments,
            directory: cwd.map { URL(fileURLWithPath: $0) }, environment: environment)
        try? process.input.close()
        let id = TerminalId(UUID().uuidString)
        let output = EditorWindowsACPTransport.chunks(process.output)
        let errors = EditorWindowsACPTransport.chunks(process.error)
        let completion = Task {
            async let out: Void = collect(output, terminal: id)
            async let err: Void = collect(errors, terminal: id)
            var code: Int32 = 0
            for await status in process.exit { code = status }
            process.terminate()
            _ = await (out, err)
            terminals[id]?.exitCode = code
            return code
        }
        terminals[id] = Terminal(session: sessionId, process: process, completion: completion,
            limit: max(0, min(outputByteLimit ?? 1024 * 1024, 16 * 1024 * 1024)))
        return CreateTerminalResponse(terminalId: id)
    }

    func handleTerminalOutput(terminalId: TerminalId, sessionId: String) throws -> TerminalOutputResponse {
        let terminal = try terminal(terminalId, session: sessionId)
        return TerminalOutputResponse(output: String(decoding: terminal.output, as: UTF8.self),
            exitStatus: terminal.exitCode.map { TerminalExitStatus(exitCode: Int($0)) }, truncated: terminal.truncated)
    }

    func handleTerminalWaitForExit(terminalId: TerminalId, sessionId: String) async throws -> WaitForExitResponse {
        let terminal = try terminal(terminalId, session: sessionId)
        return WaitForExitResponse(exitCode: Int(await terminal.completion.value))
    }

    func handleTerminalKill(terminalId: TerminalId, sessionId: String) async throws -> KillTerminalResponse {
        let terminal = try terminal(terminalId, session: sessionId)
        terminal.process.terminate()
        _ = await terminal.completion.value
        return KillTerminalResponse(success: true)
    }

    func handleTerminalRelease(terminalId: TerminalId, sessionId: String) async throws -> ReleaseTerminalResponse {
        _ = try await handleTerminalKill(terminalId: terminalId, sessionId: sessionId)
        terminals.removeValue(forKey: terminalId)
        return ReleaseTerminalResponse(success: true)
    }

    func shutdown() async {
        let current = terminals.values.map { ($0.process, $0.completion) }
        for (process, _) in current { process.terminate() }
        for (_, task) in current { _ = await task.value }
        terminals.removeAll()
    }

    private func terminal(_ id: TerminalId, session: String) throws -> Terminal {
        guard let terminal = terminals[id], terminal.session == session else { throw ClientError.transportError("Unknown terminal for this ACP session.") }
        return terminal
    }

    private func collect(_ chunks: AsyncThrowingStream<Data, any Error>, terminal id: TerminalId) async {
        do {
            for try await chunk in chunks {
                guard var terminal = terminals[id] else { continue }
                terminal.output.append(chunk)
                if terminal.output.count > terminal.limit {
                    terminal.output.removeFirst(terminal.output.count - terminal.limit)
                    terminal.truncated = true
                }
                terminals[id] = terminal
            }
        } catch {
            terminals[id]?.process.terminate()
        }
    }
}
#endif
