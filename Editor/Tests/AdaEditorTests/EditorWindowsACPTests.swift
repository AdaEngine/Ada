#if os(Windows)
import ACPModel
import Foundation
import Testing
@testable import AdaEditor

@Suite("Windows ACP agents", .serialized)
struct EditorWindowsACPTests {
    @Test("Real stdio exchanges Unicode updates, file callbacks, terminals and permission denials")
    func protocolRoundTrip() async throws {
        let fixture = try Fixture(mode: "tools")
        defer { fixture.remove() }
        let service = EditorACPAgentService()
        let recorder = Recorder()
        do {
            let result = try await service.send(fixture.request, onEvent: { await recorder.record($0) }, onProjectFileChanged: { await recorder.changed($0) })
            #expect(result.assistantText == "Готово 🌈")
            #expect(await recorder.files == ["Файл & тест.txt"])
            #expect(try String(contentsOf: fixture.root.appendingPathComponent("Файл & тест.txt"), encoding: .utf8) == "Первая\nВторая 🌈")
            #expect(!FileManager.default.fileExists(atPath: fixture.root.deletingLastPathComponent().appendingPathComponent("escape.txt").path))
            #expect(await recorder.events.contains { $0.permission?.state == .cancelled })
        } catch { await service.shutdown(); throw error }
        await service.shutdown()
    }

    @Test("Cancel interrupts an active prompt and preserves subsequent turns")
    func cancellation() async throws {
        let fixture = try Fixture(mode: "cancel")
        defer { fixture.remove() }
        let service = EditorACPAgentService()
        do {
            _ = try await service.connect(fixture.request, onEvent: { _ in }, onProjectFileChanged: { _ in })
            let run = Task { try await service.send(fixture.request, onEvent: { _ in }, onProjectFileChanged: { _ in }) }
            try await fixture.waitFor("prompt-started")
            await service.cancel(sessionID: fixture.request.session.id)
            #expect(try await run.value.stopReason == "cancelled")
            let next = try await service.send(fixture.request, onEvent: { _ in }, onProjectFileChanged: { _ in })
            #expect(next.assistantText == "Again")
        } catch { await service.shutdown(); throw error }
        await service.shutdown()
    }

    @Test("An immediate permission decision is delivered without a registration race")
    func immediatePermission() async throws {
        var fixture = try Fixture(mode: "allow")
        fixture.request.project.ai.agent.permissionMode = .allowOnce
        defer { fixture.remove() }
        let service = EditorACPAgentService()
        do {
            let result = try await service.send(fixture.request, onEvent: { event in
                if let permission = event.permission, permission.state == .pending {
                    await service.resolvePermission(requestID: permission.id, optionID: "allow")
                }
            }, onProjectFileChanged: { _ in })
            #expect(result.assistantText == "Again")
        } catch { await service.shutdown(); throw error }
        await service.shutdown()
    }

    @Test("Restoring a session accepts a standard load response without an echoed session ID")
    func restoresSession() async throws {
        var fixture = try Fixture(mode: "load")
        defer { fixture.remove() }
        fixture.request.session.upstreamSessionID = "windows-session"
        fixture.request.session.agentTargetIdentity = fixture.request.project.ai.agent.target.sessionIdentity
        let service = EditorACPAgentService()
        do {
            _ = try await service.connect(fixture.request, onEvent: { _ in }, onProjectFileChanged: { _ in })
            let result = try await service.send(fixture.request, onEvent: { _ in }, onProjectFileChanged: { _ in })
            #expect(result.upstreamSessionID == "windows-session" && result.assistantText == "Again")
            #expect(try String(contentsOf: fixture.root.appendingPathComponent("session-method"), encoding: .utf8) == "session/load")
        } catch { await service.shutdown(); throw error }
        await service.shutdown()
    }

    @Test("Shutdown terminates the adapter and its children")
    func processTree() async throws {
        let fixture = try Fixture(mode: "tree")
        defer { fixture.remove() }
        let service = EditorACPAgentService()
        do {
            _ = try await service.connect(fixture.request, onEvent: { _ in }, onProjectFileChanged: { _ in })
        } catch { await service.shutdown(); throw error }
        await service.shutdown()
        try await Task.sleep(for: .milliseconds(1300))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("orphan-marker").path))
    }

    @Test("Terminal output is bounded and terminal IDs are scoped to their session")
    func terminalLimits() async throws {
        let fixture = try Fixture(mode: "cancel")
        defer { fixture.remove() }
        let terminal = TerminalDelegate()
        do {
            let created = try await terminal.handleTerminalCreate(command: EditorHostTools.executable("python3", windowsName: "python.exe"),
                sessionId: "owner", args: ["-c", "print('x' * 4096)"], cwd: fixture.root.path, env: nil, outputByteLimit: 128)
            _ = try await terminal.handleTerminalWaitForExit(terminalId: created.terminalId, sessionId: "owner")
            let output = try await terminal.handleTerminalOutput(terminalId: created.terminalId, sessionId: "owner")
            #expect(output.output.utf8.count <= 128 && output.truncated)
            #expect(output.exitStatus?.exitCode == 0)
            await #expect(throws: ClientError.self) {
                _ = try await terminal.handleTerminalOutput(terminalId: created.terminalId, sessionId: "other")
            }
            _ = try await terminal.handleTerminalRelease(terminalId: created.terminalId, sessionId: "owner")
        } catch { await terminal.shutdown(); throw error }
        await terminal.shutdown()
    }

    @Test("Malformed stdout and abrupt process exits fail requests without hanging", arguments: ["invalid", "exit"])
    func brokenAdapter(mode: String) async throws {
        let fixture = try Fixture(mode: mode)
        defer { fixture.remove() }
        let service = EditorACPAgentService()
        do {
            _ = try await service.send(fixture.request, onEvent: { _ in }, onProjectFileChanged: { _ in })
            Issue.record("Broken adapter unexpectedly returned a successful prompt")
        } catch {
            #expect(error.localizedDescription.contains(mode == "exit" ? "fixture-exit" : "invalid"))
        }
        await service.shutdown()
    }

    @Test("Windows discovery handles Path, executable extensions and user npm directories")
    func discoveryAndEnvironment() throws {
        let fixture = try Fixture(mode: "cancel")
        defer { fixture.remove() }
        let shim = fixture.root.appendingPathComponent("codex-acp.cmd")
        try "@echo off\n".write(to: shim, atomically: true, encoding: .utf8)
        let paths = EditorAgentDiscovery.searchPaths(environment: ["Path": fixture.root.path + ";.;" + fixture.root.path], home: fixture.root)
        #expect(paths.filter { $0 == fixture.root.path }.count == 1)
        #expect(!paths.contains("."))
        #expect(paths.contains(fixture.root.appendingPathComponent("AppData/Roaming/npm").path))
        #expect(EditorAgentDiscovery.discover(paths: paths).first { $0.id == "codex-acp" }?.target?.command == shim.path)
        let environment = EditorWindowsAgentCommand.environment(["PATH": fixture.root.path, "KEY": "literal & %"], inheriting: ["Path": "old", "SystemRoot": "C:/Windows"])
        #expect(environment.filter { $0.key.lowercased() == "path" }.count == 1)
        #expect(environment["PATH"]?.components(separatedBy: ";").first == fixture.root.path)
        #expect(environment["SystemRoot"] == "C:/Windows" && environment["KEY"] == "literal & %")
        #expect(EditorRegistryAgent.platform.hasPrefix("windows-"))
    }

    @Test("Desktop Codex installs are discovered again after installation and version rotation")
    func desktopCodexDiscovery() async throws {
        let fixture = try Fixture(mode: "cancel")
        defer { fixture.remove() }
        let local = fixture.root.appendingPathComponent("AppData/Local")
        let environment = ["Path": fixture.root.path, "LOCALAPPDATA": local.path]
        let catalog = EditorAgentCatalogService(root: fixture.root.appendingPathComponent("catalog"), home: fixture.root, environment: { environment })
        #expect(await catalog.discover().contains { $0.id == "codex-acp" } == false)

        let versions = local.appendingPathComponent("OpenAI/Codex/bin")
        let old = versions.appendingPathComponent("old-hash/codex.exe")
        let current = versions.appendingPathComponent("current-hash/codex.exe")
        for binary in [old, current] {
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: EditorHostTools.executable("python3", windowsName: "python.exe"), toPath: binary.path)
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: current.path)
        var found = try #require(await catalog.discover().first { $0.id == "codex-acp" })
        #expect(found.path == current.path)
        #expect(found.target == nil)

        try FileManager.default.removeItem(at: current)
        found = try #require(await catalog.discover().first { $0.id == "codex-acp" })
        #expect(found.path == old.path)
        let stale = versions.appendingPathComponent("deleted-hash").path
        let launched = EditorWindowsAgentCommand.environment(["PATH": stale, "LITERAL": "value & %"], inheriting: environment)
        let paths = EditorAgentDiscovery.searchPaths(environment: launched, home: fixture.root)
        #expect(EditorAgentDiscovery.executable("codex", paths: paths) == old.path)
        #expect(launched["LITERAL"] == "value & %")
        #expect(launched.filter { $0.key.lowercased() == "path" }.count == 1)
        #expect(paths.contains(local.appendingPathComponent("Sloppy/bin").path))
    }

    @Test("Npm launchers resolve to Node argv without interpreting shell metacharacters", .enabled(if: ProcessInfo.processInfo.environment["ADAEDITOR_TEST_NODE"] != nil))
    func npmShim() async throws {
        guard let node = ProcessInfo.processInfo.environment["ADAEDITOR_TEST_NODE"] else {
            throw TestNodeUnavailable()
        }
        let fixture = try Fixture(mode: "cancel")
        defer { fixture.remove() }
        let cli = fixture.root.appendingPathComponent("node_modules/test/cli.js")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "console.log(JSON.stringify(process.argv.slice(2)))".write(to: cli, atomically: true, encoding: .utf8)
        let shim = fixture.root.appendingPathComponent("test.cmd")
        try #"@"%dp0%\node.exe" "%dp0%\node_modules\test\cli.js" %*"#.write(to: shim, atomically: true, encoding: .utf8)
        let environment = ["Path": URL(fileURLWithPath: node).deletingLastPathComponent().path]
        let arguments = ["Игра & путь", "%PATH%", "a\"b", "", "x^|y"]
        let invocation = try EditorWindowsAgentCommand.resolve(shim.path, arguments: arguments, environment: environment)
        #expect(invocation.executable.path == URL(fileURLWithPath: node).path)
        let process = try EditorWindowsProcess(executable: invocation.executable, arguments: invocation.arguments,
            directory: fixture.root, environment: EditorHostTools.mergedEnvironment(["NODE_NO_WARNINGS": "1"]))
        try process.input.close()
        let chunks = EditorWindowsACPTransport.chunks(process.output)
        var data = Data()
        for try await chunk in chunks { data.append(chunk) }
        var code: Int32 = -1
        for await status in process.exit { code = status }
        #expect(code == 0)
        let received = try JSONDecoder().decode([String].self, from: data)
        #expect(received == arguments)
    }

    @Test("Windows archives reject drive paths, alternate streams, traversal and links")
    func archivePaths() throws {
        try EditorAgentCatalogService.validateArchive(names: "./agent.exe\n", details: "-rw-r--r-- agent.exe\n", command: "./agent.exe")
        for path in ["C:/escape.exe", "agent.exe:stream", "../escape", "\\\\server\\share\\a", "/absolute"] {
            #expect(throws: EditorAgentCatalogError.self) {
                try EditorAgentCatalogService.validateArchive(names: path, details: "-rw-r--r--", command: "agent.exe")
            }
        }
        #expect(throws: EditorAgentCatalogError.self) {
            try EditorAgentCatalogService.validateArchive(names: "agent.exe\r\n../escape\r\n", details: "-rw-r--r--\r\n-rw-r--r--\r\n", command: "agent.exe")
        }
    }

    @Test("Installed desktop Codex is found without its executable directory in PATH",
          .enabled(if: ProcessInfo.processInfo.environment["ADAEDITOR_DESKTOP_AGENTS_LIVE_TEST"] == "1"))
    func liveDesktopCodexDiscovery() async throws {
        let catalog = EditorAgentCatalogService(environment: {
            EditorHostTools.mergedEnvironment(["PATH": "C:/Windows/System32"], inheriting: ProcessInfo.processInfo.environment)
        })
        let codex = try #require(await catalog.discover().first { $0.id == "codex-acp" })
        #expect(codex.path.lowercased().hasSuffix("codex.exe"))
        #expect(FileManager.default.isExecutableFile(atPath: codex.path))
    }

    @Test("Installed Sloppy initializes and creates a session through the Studio agent service",
          .enabled(if: ProcessInfo.processInfo.environment["ADAEDITOR_DESKTOP_AGENTS_LIVE_TEST"] == "1"))
    func liveSloppyConnection() async throws {
        let catalog = EditorAgentCatalogService()
        let sloppy = try #require(await catalog.discover().first { $0.id == "sloppy-acp" })
        var fixture = try Fixture(mode: "cancel")
        defer { fixture.remove() }
        fixture.request.project.ai.agent.target = try #require(sloppy.target)
        fixture.request.project.ai.mcp.enabled = false
        let service = EditorACPAgentService()
        do {
            let configuration = try await service.connect(fixture.request, onEvent: { _ in }, onProjectFileChanged: { _ in })
            #expect(configuration.agentName == "Sloppy")
        } catch { await service.shutdown(); throw error }
        await service.shutdown()
    }

    @Test("Official registry npm and Windows binary distributions install and initialize",
          .enabled(if: ProcessInfo.processInfo.environment["ADAEDITOR_ACP_LIVE_TEST"] == "1"), arguments: ["codex-acp", "amp-acp"])
    func liveRegistry(agentID: String) async throws {
        let fixture = try Fixture(mode: "cancel")
        defer { fixture.remove() }
        let catalog = EditorAgentCatalogService(root: fixture.root.appendingPathComponent("catalog"))
        let agents = try await catalog.refresh()
        let agent = try #require(agents.first { $0.id == agentID })
        let entry = try await catalog.install(agent)
        if agent.distribution.binary?[EditorRegistryAgent.platform] != nil {
            #expect(entry.target.command?.lowercased().hasSuffix(".exe") == true)
        } else {
            #expect(entry.target.command?.lowercased().hasSuffix(".cmd") == true)
        }
        let client = Client()
        do {
            try await client.launch(agentPath: try #require(entry.target.command), arguments: entry.target.arguments,
                workingDirectory: fixture.root.path, environment: entry.target.environment)
            let initialized = try await client.initialize(capabilities: ClientCapabilities(fs: .init(readTextFile: true, writeTextFile: true), terminal: true))
            #expect(initialized.protocolVersion == 1)
            #expect(initialized.agentInfo?.name.isEmpty == false)
            #expect(try await catalog.installed() == [entry])
        } catch { await client.terminate(); throw error }
        await client.terminate()
    }

    private struct TestNodeUnavailable: Error {}

    private actor Recorder {
        var events: [EditorAgentEvent] = []
        var files: [String] = []
        func record(_ event: EditorAgentEvent) { events.append(event) }
        func changed(_ path: String) { files.append(path) }
    }

    private struct Fixture {
        let root: URL
        var request: EditorAgentRunRequest

        init(mode: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ACP Игра & \(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let script = root.appendingPathComponent("agent.py")
            try EditorWindowsACPTests.agentScript.write(to: script, atomically: true, encoding: .utf8)
            var project = ProjectSystem.defaultProject(projectName: "Windows ACP")
            project.ai.agent.enabled = true
            project.ai.agent.permissionMode = .deny
            project.ai.agent.target = .init(command: EditorHostTools.executable("python3", windowsName: "python.exe"),
                arguments: ["-u", script.path, mode], environment: ["PYTHONIOENCODING": "utf-8"])
            request = .init(project: project, projectURL: root, session: EditorAgentSession(), mode: .build, prompt: "Synthetic protocol check",
                attachments: [], sceneContext: nil, codeSelection: nil, skills: [])
        }

        func waitFor(_ name: String) async throws {
            for _ in 0..<500 {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ClientError.requestTimeout
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private static let agentScript = #"""
    import json, sys, os, subprocess
    mode = sys.argv[1]
    session = "windows-session"
    active = None
    turns = 0
    def emit(value):
        data = (json.dumps(value, ensure_ascii=False) + "\n").encode("utf-8")
        for offset in range(0, len(data), 3): os.write(1, data[offset:offset+3])
    def respond(request, result): emit({"jsonrpc":"2.0", "id":request["id"], "result":result})
    def call(method, params):
        params["sessionId"] = session
        emit({"jsonrpc":"2.0", "id":"agent-call", "method":method, "params":params})
        reply = json.loads(sys.stdin.readline())
        assert reply["id"] == "agent-call", reply
        return reply
    for line in sys.stdin:
        req = json.loads(line)
        method = req.get("method")
        if method == "initialize":
            if mode == "tree":
                subprocess.Popen([sys.executable,"-c","import time; time.sleep(1); open('orphan-marker', 'w').close()"])
            respond(req, {"protocolVersion":1,"agentCapabilities":{"loadSession":True},"agentInfo":{"name":"Windows fixture","version":"1"}})
        elif method in ["session/new", "session/load"]:
            with open("session-method", "w") as output: output.write(method)
            respond(req, {"sessionId":session} if method == "session/new" else {})
        elif method == "session/cancel":
            respond(active, {"stopReason":"cancelled"})
            active = None
        elif method == "session/prompt":
            turns += 1
            if mode == "invalid":
                print("this is not JSON-RPC", flush=True)
                continue
            if mode == "exit":
                print("fixture-exit", file=sys.stderr, flush=True)
                sys.exit(7)
            if mode == "cancel" and turns == 1:
                active = req
                open("prompt-started", "w").close()
                continue
            if mode == "tools":
                file = os.path.join(os.getcwd(), "Файл & тест.txt")
                written = call("fs/write_text_file", {"path":file,"content":"Первая\nВторая 🌈"})
                assert "result" in written, written
                assert call("fs/read_text_file", {"path":file,"line":2,"limit":1})["result"]["content"] == "Вторая 🌈"
                assert call("fs/read_text_file", {"path":file,"line":1000,"limit":1})["result"]["content"] == ""
                assert "error" in call("fs/write_text_file", {"path":os.path.join(os.path.dirname(os.getcwd()),"escape.txt"),"content":"bad"})
                terminal = call("terminal/create", {"command":sys.executable,"args":["-c","import os; print('Терминал 🌈 ' + os.environ['ACP_ARG'])"],
                    "cwd":os.getcwd(),"env":[{"name":"ACP_ARG","value":"literal & %"},{"name":"PYTHONIOENCODING","value":"utf-8"}],"outputByteLimit":4096})["result"]["terminalId"]
                exited = call("terminal/wait_for_exit", {"terminalId":terminal})
                assert exited["result"]["exitCode"] == 0, exited
                output = call("terminal/output", {"terminalId":terminal})["result"]
                assert "Терминал 🌈 literal & %" in output["output"], output
                assert "result" in call("terminal/release", {"terminalId":terminal})
                permission = call("session/request_permission", {"message":"Synthetic approval", "toolCall":{"toolCallId":"fixture"},
                    "options":[{"kind":"allow_once","name":"Allow","optionId":"allow"}]})
                assert permission["result"]["outcome"]["outcome"] == "cancelled", permission
            if mode == "allow":
                permission = call("session/request_permission", {"message":"Synthetic approval", "toolCall":{"toolCallId":"fixture"},
                    "options":[{"kind":"allow_once","name":"Allow","optionId":"allow"}]})
                assert permission["result"]["outcome"]["optionId"] == "allow", permission
            text = "Готово 🌈" if mode == "tools" else "Again"
            emit({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":session,
                "update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":text}}}})
            respond(req, {"stopReason":"end_turn"})
    """#
}
#endif
