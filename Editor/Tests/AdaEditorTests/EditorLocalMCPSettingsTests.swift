#if os(macOS) || os(Windows)
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Local MCP tools in Ada AI", .serialized)
struct EditorLocalMCPSettingsTests {
    @Test func validatesOnlySupportedSchemas() throws {
        let shape = try EditorLocalMCPToolSchema([
            "type": "object", "required": ["values"], "additionalProperties": false,
            "properties": ["values": ["type": "array", "minItems": 1, "maxItems": 2, "items": ["type": "integer", "minimum": 2]]]
        ])
        try shape.validate(["values": [2, 3]])
        #expect(throws: (any Error).self) { try shape.validate(["values": [1]]) }
        #expect(throws: (any Error).self) { try shape.validate(["values": [2], "extra": true]) }
        #expect(throws: (any Error).self) { try shape.validate([:]) }
        #expect(throws: (any Error).self) { try EditorLocalMCPToolSchema(["type": "object", "$ref": "https://example.test/schema"] as EditorCloudValue) }
        #expect(throws: (any Error).self) { try EditorLocalMCPToolSchema(["type": "object", "properties": ["code": ["pattern": ".*"]]]) }
        let escaped: EditorCloudValue = ["type": "object", "description": .string(String(repeating: "\u{0001}", count: 3_000))]
        #expect(throws: (any Error).self) { try EditorLocalMCPToolSchema(escaped) }
    }

    @Test func onlyBoundedTextAndStructuredResultsReachCloud() throws {
        let encoded = try EditorLocalMCPTool.boundedResult([
            "structuredContent": ["answer": 42], "_meta": ["private": "never forwarded"],
            "content": [["type": "text", "text": "safe\u{001b}"], ["type": "image", "data": "binary data"]]
        ])
        let result = try JSONDecoder().decode(EditorCloudValue.self, from: Data(encoded.utf8))
        #expect(result["result"]["answer"].int == 42)
        #expect(result["text"].array == ["safe"])
        #expect(result["truncated"].bool == true)
        #expect(!encoded.contains("never forwarded") && !encoded.contains("binary data"))
        let oversized = try EditorLocalMCPTool.boundedResult(["structuredContent": ["large": .string(String(repeating: "x", count: 8_001))]])
        #expect(!oversized.contains("large"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADA_STUDIO_MCP_TEST_PYTHON"] != nil))
    func usesDistinctServersAndRechecksSelectionAfterApproval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ada MCP Settings \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("local-mcp.json")
        let settings = EditorLocalMCPSettings(fileURL: file)
        let first = try configure("First Catalog", settings: settings)
        let second = try configure("Second Catalog", settings: settings)
        await settings.connect(first)
        await settings.connect(second)
        defer { Task { await settings.disconnect(first); await settings.disconnect(second) } }
        let firstTool = try echo(first, settings: settings)
        let secondTool = try echo(second, settings: settings)
        #expect(firstTool.alias != secondTool.alias)
        #expect(settings.cloudTools(isCurrentProject: { true }).isEmpty)
        settings.select(firstTool, server: first, enabled: true)
        settings.select(secondTool, server: second, enabled: true)
        let deniedCatalog = settings.cloudTools(isCurrentProject: { true }, mayInvoke: { false })
        let list = try #require(deniedCatalog.first { $0.name == "editor_external_list" })
        let listing = try await list.invoke([:])
        #expect(listing.contains(firstTool.alias) && listing.contains(secondTool.alias))

        let factory: EditorCloudAgentService.ToolsFactory = { _ in await settings.cloudTools(isCurrentProject: { true }) }
        let accepted = try await run(secondTool.alias, value: "from Build", mode: .build, directory: directory, tools: factory) { _ in true }
        #expect(accepted["result"]["server"].string == "Second Catalog")
        #expect(accepted["result"]["value"].string == "from Build")

        let denied = try await run(firstTool.alias, value: "deny", mode: .build, directory: directory, tools: factory) { _ in false }
        #expect(denied.string?.contains(L10n.tr("The user declined this project change.")) == true)
        let invalid = try await run(firstTool.alias, value: String(repeating: "a", count: 41), mode: .build, directory: directory, tools: factory) { _ in
            Issue.record("Invalid input reached the permission prompt.")
            return true
        }
        #expect(invalid.string?.contains(L10n.tr("The tool arguments do not match the MCP input schema.")) == true)
        let planned = try await run(firstTool.alias, value: "Plan", mode: .plan, directory: directory, tools: factory) { _ in
            Issue.record("Plan attempted to request invocation approval.")
            return true
        }
        #expect(planned.string?.hasPrefix("Tool failed:") == true)
        await #expect(throws: CancellationError.self) {
            try await run(firstTool.alias, value: "cancel", mode: .build, directory: directory, tools: factory, cancelBeforeApproval: true) { _ in
                Issue.record("Cancellation reached the permission prompt.")
                return true
            }
        }

        let stale = try await run(firstTool.alias, value: "revoke", mode: .build, directory: directory, tools: factory) { permission in
            #expect(permission.summary.contains("First Catalog") && permission.summary.contains("echo"))
            #expect(permission.inputDetails?.contains("revoke") == true)
            await settings.select(firstTool, server: first, enabled: false)
            return true
        }
        #expect(stale.string?.contains(L10n.tr("This local MCP tool is no longer available. Review the connection and try again.")) == true)
        await settings.disconnect(second)
        let reloaded = EditorLocalMCPSettings(fileURL: file)
        #expect(reloaded.connections.isEmpty)
        await reloaded.connect(second)
        let restoredTool = try echo(second, settings: reloaded)
        #expect(reloaded.isSelected(restoredTool, server: second))
        await reloaded.disconnect(second)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADA_STUDIO_MCP_TEST_PYTHON"] != nil))
    func fullyDisclosesArgumentsAndRevokesChangedSchema() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ada MCP Review \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = EditorLocalMCPSettings()
        let id = try configure("Long input", settings: settings)
        let config = try #require(settings.servers.first)
        let fixture = try String(contentsOfFile: config.arguments[0], encoding: .utf8)
        let script = directory.appendingPathComponent("server.py")
        try fixture.replacingOccurrences(of: "maxLength\": 40", with: "maxLength\": 1_500").write(to: script, atomically: true, encoding: .utf8)
        settings.edit(id) { $0.arguments[0] = script.path }
        await settings.connect(id)
        let entry = try echo(id, settings: settings)
        settings.select(entry, server: id, enabled: true)
        let workspace = EditorViewModel(project: EditorProjectReference(name: "MCP review", path: directory.path))
        let other = EditorViewModel(project: EditorProjectReference(name: "Other", path: directory.appendingPathComponent("Other").path))
        let registry = EditorAgentMCPTools.shared
        registry.activate(workspace)
        defer { registry.deactivate(workspace) }
        let generation = registry.workspaceGeneration
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let factory: EditorCloudAgentService.ToolsFactory = { _ in
            await settings.cloudTools(isCurrentProject: { await registry.isCurrentWorkspace(root, generation: generation) })
        }
        let value = String(repeating: "a", count: 900) + "[last argument](https://example.test/)"
        let result = try await run(entry.alias, value: value, mode: .build, directory: directory, tools: factory) { permission in
            let details = permission.inputDetails ?? ""
            let input = try? JSONDecoder().decode(EditorCloudValue.self, from: Data(details.utf8))
            #expect(input?["value"].string == value)
            await MainActor.run { registry.activate(other); registry.activate(workspace) }
            return true
        }
        #expect(result.string?.contains(L10n.tr("This local MCP tool is no longer available. Review the connection and try again.")) == true)
        await settings.disconnect(id)
        try fixture.write(to: script, atomically: true, encoding: .utf8)
        await settings.connect(id)
        let updated = try echo(id, settings: settings)
        #expect(entry.alias == updated.alias && entry.fingerprint != updated.fingerprint)
        #expect(!settings.isSelected(updated, server: id))
        await settings.disconnect(id)
    }

    #if os(macOS)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADA_STUDIO_MCP_TEST_PYTHON"] != nil))
    func disconnectStopsDescendantsThatInheritedStdio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ada MCP Group \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = EditorLocalMCPSettings()
        let id = try configure("Process fixture", settings: settings)
        let fixture = try #require(settings.servers.first).arguments[0]
        let server = directory.appendingPathComponent("server.py")
        let receipt = directory.appendingPathComponent("receipt.txt")
        let started = directory.appendingPathComponent("started.txt")
        let content = """
        import subprocess, sys
        child = "import pathlib, sys, time; pathlib.Path(sys.argv[1]).touch(); time.sleep(1); pathlib.Path(sys.argv[2]).touch()"
        subprocess.Popen([sys.executable, "-c", child, sys.argv[2], sys.argv[3]])
        """ + "\n" + (try String(contentsOfFile: fixture, encoding: .utf8))
        try content.write(to: server, atomically: true, encoding: .utf8)
        settings.edit(id) { $0.arguments = [server.path, "Fixture", started.path, receipt.path] }
        await settings.connect(id)
        _ = try echo(id, settings: settings)
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: started.path))
        await settings.disconnect(id)
        try await Task.sleep(for: .seconds(1.2))
        #expect(!FileManager.default.fileExists(atPath: receipt.path))
    }
    #endif

    private func configure(_ name: String, settings: EditorLocalMCPSettings) throws -> UUID {
        let python = try #require(ProcessInfo.processInfo.environment["ADA_STUDIO_MCP_TEST_PYTHON"])
        let id = try #require(settings.add())
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/LocalMCP/server.py")
        settings.edit(id) {
            $0.name = name
            $0.executable = python
            $0.arguments = [fixture.path, name]
        }
        return id
    }

    private func echo(_ id: UUID, settings: EditorLocalMCPSettings) throws -> EditorLocalMCPTool {
        try #require(settings.connections[id]?.tools.first { $0.id == "echo" }, "\(settings.errors[id] ?? "No tool")")
    }

    private func run(_ alias: String, value: String, mode: EditorAgentChatMode, directory: URL, tools: @escaping EditorCloudAgentService.ToolsFactory,
                     cancelBeforeApproval: Bool = false,
                     approval: @escaping @Sendable (EditorAgentPermissionRequest) async -> Bool) async throws -> EditorCloudValue {
        let model = Model(alias: alias, value: value)
        let service = EditorCloudAgentService(connectionFactory: {
            EditorCloudAIConnection(toolContract: 2, supportsExternalTools: true) { input, receive in try await model.respond(input, receive: receive) }
        }, toolsFactory: tools)
        var project = ProjectSystem.defaultProject(buildSystem: .adaScript)
        project.ai.agent.enabled = true
        let request = EditorAgentRunRequest(project: project, projectURL: directory, session: .init(id: UUID().uuidString), mode: mode,
                                            prompt: "Use the selected local tool", attachments: [], sceneContext: nil, codeSelection: nil, skills: [])
        _ = try await service.send(request, onEvent: { event in
            if cancelBeforeApproval, event.toolCall?.status == .inProgress {
                await service.cancel(sessionID: request.session.id)
            }
            if let permission = event.permission {
                let allow = await approval(permission)
                await service.resolvePermission(requestID: permission.id, optionID: allow ? "allow" : "deny")
            }
        }, onProjectFileChanged: { _ in Issue.record("A generic tool result reported a project-file change.") })
        return await model.result
    }

    private actor Model {
        let alias: String
        let value: String
        private(set) var result: EditorCloudValue = .null

        init(alias: String, value: String) {
            self.alias = alias
            self.value = value
        }

        func respond(_ input: EditorCloudValue, receive: @escaping @Sendable (EditorCloudValue) async throws -> Void) async throws {
            #expect(input["toolContract"].int == 3)
            if let raw = input["messages"].array.last(where: { $0["role"].string == "tool" })?["content"].string {
                result = (try? JSONDecoder().decode(EditorCloudValue.self, from: Data(raw.utf8))) ?? .string(raw)
                try await receive(["type": "text", "text": "Done"])
            } else {
                let request: EditorCloudValue = ["action": "invoke", "arguments": ["tool": .string(alias), "input": ["value": .string(value)]]]
                let arguments = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
                try await receive(["type": "tool", "call": ["id": "echo", "function": ["name": "editor_external", "arguments": .string(arguments)]]])
            }
            try await receive(["type": "complete"])
        }
    }
}
#endif
