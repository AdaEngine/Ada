import Foundation
import Testing

@testable import AdaEditor

#if os(macOS)
    @Suite("Editor agent MCP connection", .serialized)
    struct EditorAgentMCPConnectionTests {
        @Test("automatic connect shares session preparation and preserves the running prompt sink")
        func concurrentConnection() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("EditorMCPConcurrent-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let script = root.appendingPathComponent("agent.py")
            try Self.agentScript.write(to: script, atomically: true, encoding: .utf8)
            var project = ProjectSystem.defaultProject(projectName: "Concurrent")
            project.ai.agent.enabled = true
            project.ai.agent.target = .init(command: "/usr/bin/python3", arguments: [script.path, "http"])
            let request = EditorAgentRunRequest(
                project: project,
                projectURL: root,
                session: EditorAgentSession(),
                mode: .build,
                prompt: "test",
                attachments: [],
                sceneContext: nil,
                codeSelection: nil,
                skills: []
            )
            let service = EditorACPAgentService()
            let recorder = MCPConnectionRecorder()
            do {
                async let connection = service.connect(request, onEvent: { _ in }, onProjectFileChanged: { _ in })
                let run = Task {
                    try await service.send(request, onEvent: { await recorder.record($0) }, onProjectFileChanged: { _ in })
                }
                _ = try await connection
                for _ in 0..<200 where !FileManager.default.fileExists(atPath: root.appendingPathComponent("prompt-started").path) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                _ = try await service.connect(request, onEvent: { _ in }, onProjectFileChanged: { _ in })
                let result = try await run.value
                #expect(result.assistantText == "Hello world")
                #expect(await recorder.chunks == ["Hello", " world"])
                let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
                #expect(requests.split(separator: "\n").count == 1)
            } catch {
                await service.shutdown()
                throw error
            }
            await service.shutdown()
        }

        @Test("ACP advertises editor tools for new and restored sessions and reconnects on MCP changes", arguments: [true, false], [true, false])
        func sessionTools(supportsHTTP: Bool, restored: Bool) async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("EditorMCP-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let script = root.appendingPathComponent("agent.py")
            try Self.agentScript.write(to: script, atomically: true, encoding: .utf8)
            var project = ProjectSystem.defaultProject(projectName: "MCP")
            project.ai.agent.enabled = true
            project.ai.mcp.enabled = true
            project.ai.agent.target = .init(command: "/usr/bin/python3", arguments: [script.path, supportsHTTP ? "http" : "stdio"])
            var session = EditorAgentSession()
            if restored {
                session.upstreamSessionID = "saved-session"
                session.agentTargetIdentity = project.ai.agent.target.sessionIdentity
            }
            var request = EditorAgentRunRequest(
                project: project,
                projectURL: root,
                session: session,
                mode: .build,
                prompt: "",
                attachments: [],
                sceneContext: nil,
                codeSelection: nil,
                skills: []
            )
            let service = EditorACPAgentService()
            do {
                _ = try await service.connect(request, onEvent: { _ in }, onProjectFileChanged: { _ in })
                request.project.ai.mcp.enabled = false
                _ = try await service.connect(request, onEvent: { _ in }, onProjectFileChanged: { _ in })
                request.project.ai.mcp.enabled = true
                _ = try await service.connect(request, onEvent: { _ in }, onProjectFileChanged: { _ in })
            } catch {
                await service.shutdown()
                throw error
            }
            await service.shutdown()
            let lines = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
                .split(separator: "\n")
            let messages = try lines.map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            #expect(messages.count == 3)
            for (index, message) in messages.enumerated() {
                #expect(message["method"] as? String == (restored ? "session/load" : "session/new"))
                let params = try #require(message["params"] as? [String: Any])
                let servers = try #require(params["mcpServers"] as? [[String: Any]])
                if index == 1 {
                    #expect(servers.isEmpty)
                } else {
                    #expect(servers.count == 1)
                    let server = try #require(servers.first)
                    #expect(server["name"] as? String == "AdaEditor")
                    if supportsHTTP {
                        #expect(server["type"] as? String == "http")
                        #expect(server["url"] as? String == EditorMCPServerAddress.url)
                    } else {
                        #expect(server["type"] as? String == "stdio")
                        #expect((server["command"] as? String)?.isEmpty == false)
                        #expect(server["args"] as? [String] == [EditorAgentMCPConnection.bridgeArgument, "--mcp-port=\(EditorMCPServerAddress.port)"])
                    }
                }
            }
        }

        @Test("stdio bridge preserves HTTP session and forwards tool results and connection errors")
        func bridgeTransport() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("EditorMCPBridge-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let script = root.appendingPathComponent("server.py")
            try Self.serverScript.write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path]
            process.currentDirectoryURL = root
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            let address = root.appendingPathComponent("address")
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: address.path) {
                try await Task.sleep(for: .milliseconds(10))
            }
            let endpoint = URL(string: try String(contentsOf: address, encoding: .utf8))
            let bridge = EditorAgentMCPStdioBridge(endpoint: endpoint)
            let initialized = await bridge.forward(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#.utf8))
            let initial = try #require(initialized)
            #expect(String(data: initial, encoding: .utf8)?.contains("protocolVersion") == true)
            let notification = await bridge.forward(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
            #expect(notification == nil)
            let result = await bridge.forward(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8))
            let payload = try #require(result)
            #expect(!payload.contains(10))
            let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            #expect(object["id"] as? Int == 2)
            let value = try #require(object["result"] as? [String: Any])
            #expect(value["sessionVerified"] as? Bool == true)
            await bridge.disconnect()
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("disconnected").path))
            let unavailable = EditorAgentMCPStdioBridge(endpoint: nil)
            let failure = try #require(await unavailable.forward(Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#.utf8)))
            let error = try #require(JSONSerialization.jsonObject(with: failure) as? [String: Any])
            #expect(error["id"] as? Int == 3)
            #expect(error["error"] != nil)
            await unavailable.disconnect()
        }

        private static let agentScript = #"""
            import json, sys, time
            for line in sys.stdin:
                request = json.loads(line)
                method = request.get("method")
                if method == "initialize":
                    result = {"protocolVersion":1,"agentCapabilities":{"loadSession":True,"mcpCapabilities":{"http":sys.argv[1]=="http"}}}
                elif method in ["session/new", "session/load"]:
                    with open("requests.jsonl", "a") as output:
                        output.write(json.dumps(request) + "\n")
                    time.sleep(0.05)
                    result = {"sessionId":"saved-session"}
                elif method == "session/prompt":
                    open("prompt-started", "w").close()
                    for text in ["Hello", " world"]:
                        print(json.dumps({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"saved-session",
                            "update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":text}}}}), flush=True)
                        time.sleep(0.2)
                    result = {"stopReason":"end_turn"}
                else:
                    result = {}
                if "id" in request:
                    print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}), flush=True)
            """#

        private static let serverScript = #"""
            import json
            from http.server import BaseHTTPRequestHandler, HTTPServer
            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *args):
                    pass
                def do_POST(self):
                    request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    if request["method"] == "initialize":
                        result = {"protocolVersion":"2025-03-26","capabilities":{}}
                    else:
                        assert self.headers["MCP-Session-Id"] == "bridge-session"
                        assert self.headers["MCP-Protocol-Version"] == "2025-03-26"
                        result = {"sessionVerified":True}
                    if "id" not in request:
                        self.send_response(202)
                        self.end_headers()
                        return
                    body = json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result})
                    self.send_response(200)
                    self.send_header("MCP-Session-Id", "bridge-session")
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    self.wfile.write(("event: message\ndata: " + body + "\n\n").encode())
                def do_DELETE(self):
                    assert self.headers["MCP-Session-Id"] == "bridge-session"
                    open("disconnected", "w").close()
                    self.send_response(200)
                    self.end_headers()
            server = HTTPServer(("127.0.0.1", 0), Handler)
            with open("address", "w") as output:
                output.write("http://127.0.0.1:" + str(server.server_port) + "/mcp")
            server.serve_forever()
            """#
    }

    private actor MCPConnectionRecorder {
        var chunks: [String] = []

        func record(_ event: EditorAgentEvent) {
            if event.isDelta == true, let text = event.message?.segments.first?.text {
                chunks.append(text)
            }
        }
    }
#endif
