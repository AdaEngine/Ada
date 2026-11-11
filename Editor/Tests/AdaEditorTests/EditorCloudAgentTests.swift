import Foundation
import MCP
import Testing

@testable import AdaEditor

@Suite("Hosted Cloud AI native agent")
struct EditorCloudAgentTests {
    @Test func nativeVerificationMetadataSurvivesMCPEncoding() throws {
        let tool = Tool(name: "editor.build.start", inputSchema: .object([:]), _meta: Metadata(additionalFields: ["sloppy/verification": "build"]))
        let data = try JSONEncoder().encode(tool)
        let value = try JSONDecoder().decode(EditorCloudValue.self, from: data)
        #expect(value["_meta"]["sloppy/verification"].string == "build")
        #expect(try JSONDecoder().decode(Tool.self, from: data) == tool)
    }
    func request(mode: EditorAgentChatMode = .build) -> EditorAgentRunRequest {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-agent-fixture")
        var project = ProjectSystem.defaultProject(buildSystem: .adaScript)
        project.ai.agent.enabled = true
        return .init(
            project: project, projectURL: url, session: .init(id: "session"), mode: mode,
            prompt: "Create a game", attachments: [], sceneContext: nil, codeSelection: nil, skills: [])
    }
    @Test func normalizedStreamRequiresCompletionAndRejectsServerErrors() throws {
        var parser = EditorCloudAIStream()
        #expect(try parser.event(line: ": keepalive") == nil)
        _ = try parser.event(line: #"data: {"type":"text","text":"Привет"}"#)
        #expect(throws: (any Error).self) { try parser.finish() }
        _ = try parser.event(line: #"data: {"type":"complete"}"#)
        try parser.finish()
        #expect(throws: (any Error).self) { _ = try parser.event(line: #"data: {"type":"tool"}"#) }
        var failure = EditorCloudAIStream()
        #expect(throws: (any Error).self) { _ = try failure.event(line: #"data: {"type":"error","message":"secret upstream body"}"#) }
    }
    @Test func toolExecutionWaitsForPermissionAndUsesAnotherMeteredCall() async throws {
        let gateway = Gateway()
        let count = Counter()
        let tool = EditorCloudAgentTool(
            name: "editor_file_write", definition: ["type": "function"], readOnly: false,
            invoke: { _ in
                await count.increment()
                return "Saved Sources/Game.ada"
            })
        let service = EditorCloudAgentService(transportFactory: { { input, receive in try await gateway.respond(input, receive) } }, toolsFactory: { _ in [tool] })
        let result = try await service.send(
            request(),
            onEvent: { event in
                if let permission = event.permission { await service.resolvePermission(requestID: permission.id, optionID: "allow") }
            }, onProjectFileChanged: { _ in })
        #expect(result.assistantText == "Done")
        #expect(await count.value == 1)
        #expect(await gateway.operations.count == 2)
        #expect(await Set(gateway.operations).count == 2)
    }
    @Test func deniedPermissionAndPlanModeNeverMutateFiles() async throws {
        for plan in [false, true] {
            let gateway = Gateway()
            let count = Counter()
            let tool = EditorCloudAgentTool(
                name: "editor_file_write", definition: ["type": "function"], readOnly: false,
                invoke: { _ in
                    await count.increment()
                    return "Saved"
                })
            let service = EditorCloudAgentService(transportFactory: { { input, receive in try await gateway.respond(input, receive) } }, toolsFactory: { _ in [tool] })
            _ = try await service.send(
                request(mode: plan ? .plan : .build),
                onEvent: { event in
                    if let permission = event.permission { await service.resolvePermission(requestID: permission.id, optionID: "deny") }
                }, onProjectFileChanged: { _ in })
            #expect(await count.value == 0)
        }
    }
    @Test func downloadsShowTheirDestinationAndReportTheSavedFile() async throws {
        let path = "Assets/Textures/sprite.png"
        let gateway = Gateway(name: "editor_web_download", arguments: #"{"destination":"Assets/Textures/sprite.png"}"#)
        let changed = Counter()
        let tool = EditorCloudAgentTool(
            name: "editor_web_download", definition: ["type": "function"], readOnly: false, invoke: { _ in "Downloaded" })
        let service = EditorCloudAgentService(transportFactory: { { input, receive in try await gateway.respond(input, receive) } }, toolsFactory: { _ in [tool] })
        _ = try await service.send(
            request(),
            onEvent: { event in
                if let permission = event.permission {
                    #expect(permission.summary.contains(path))
                    await service.resolvePermission(requestID: permission.id, optionID: "allow")
                }
            }, onProjectFileChanged: { saved in
                #expect(saved == path)
                await changed.increment()
            })
        #expect(await changed.value == 1)
    }
    @Test(arguments: [EditorAgentChatMode.ask, .plan])
    func planningCanResearchTheWebWithoutDownloading(mode: EditorAgentChatMode) async throws {
        let count = Counter()
        let tools = ["editor_web_search", "editor_web_fetch", "editor_web_download"].map { name in
            EditorCloudAgentTool(
                name: name, definition: ["type": "function", "function": ["name": .string(name)]], readOnly: name != "editor_web_download",
                invoke: { _ in
                    await count.increment()
                    return "External reference"
                })
        }
        let service = EditorCloudAgentService(
            connectionFactory: {
                EditorCloudAIConnection(toolContract: 2) { input, receive in
                    let advertised = input["tools"].array.compactMap { $0["function"]["name"].string }
                    #expect(input["toolContract"].int == 2)
                    #expect(advertised.contains("editor_web"))
                    let web = input["tools"].array.first { $0["function"]["name"].string == "editor_web" }
                    #expect(web?["function"]["parameters"]["properties"]["action"]["enum"].array == ["search", "fetch"])
                    if await count.value == 0 {
                        let calls = [
                            ("search", #"{"action":"search","arguments":{"query":"AdaEngine"}}"#),
                            ("fetch", #"{"action":"fetch","arguments":{"url":"https://example.com"}}"#),
                            ("download", #"{"action":"download","arguments":{"url":"https://example.com","destination":"Assets/a.png"}}"#),
                        ]
                        for (id, arguments) in calls {
                            try await receive(["type": "tool", "call": ["id": .string(id), "function": ["name": "editor_web", "arguments": .string(arguments)]]])
                        }
                    } else {
                        try await receive(["type": "text", "text": "Found references"])
                    }
                    try await receive(["type": "complete"])
                }
            }, toolsFactory: { _ in tools })
        let result = try await service.send(
            request(mode: mode), onEvent: { event in #expect(event.permission == nil) }, onProjectFileChanged: { _ in Issue.record("Research changed a file") })
        #expect(result.assistantText == "Found references")
        #expect(await count.value == 2)
    }

    @Test(arguments: [false, true])
    @MainActor func groupedCatalogCoversAllNativeBindings(mobile: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host = EditorCloudToolHost(projectURL: root, mobile: mobile ? EditorMobileAgentToolService(projectURL: root) : nil)
        let tools = try host.tools()
        let platform: EditorCloudToolCatalog.Host = mobile ? .mobile : .desktop
        let catalog = try EditorCloudToolCatalog.load()
        #expect(catalog.families.count == 17)
        let selection = catalog.selection(host: platform, planning: false)
        let actions = selection.families.flatMap(\.actions)
        let names = actions.compactMap { $0.bindings[platform.rawValue] }
        #expect(names.count == Set(names).count)
        #expect(Set(names) == Set(tools.map(\.name)))
        for action in actions {
            let tool = try #require(tools.first { $0.name == action.bindings[platform.rawValue] })
            #expect(action.approval == !tool.readOnly)
            if !tool.name.hasPrefix("editor_animation_"), tool.name != "editor_project_configure" {
                let legacyRequired = tool.definition["function"]["parameters"]["required"].array.compactMap(\.string)
                let groupedRequired = action.schema(for: platform)["required"].array.compactMap(\.string)
                #expect(Set(legacyRequired).isSubset(of: Set(groupedRequired)), Comment(rawValue: tool.name))
            }
        }
        let planning = catalog.selection(host: platform, planning: true).families.flatMap(\.actions)
        #expect(planning.allSatisfy { !$0.approval })
        let edit = try selection.resolve(name: "editor_model", input: [
            "action": "edit_material", "arguments": ["path": "Assets/Cube.glb", "material": 0, "settingsJSON": #"{"roughnessFactor":0.5}"#]
        ])
        #expect(edit.approval)
        #expect(try edit.legacyArguments()["material"].int == 0)
    }

    @Test func groupedProjectAndSceneResultsHaveCommonFields() throws {
        let catalog = try EditorCloudToolCatalog.load()
        let desktop = catalog.selection(host: .desktop, planning: true)
        let mobile = catalog.selection(host: .mobile, planning: true)
        let request: EditorCloudValue = ["action": "context", "arguments": [:]]
        let desktopResult = try desktop.resolve(name: "editor_project", input: request).result(#"{"project":"Sample"}"#, host: .desktop)
        let mobileResult = try mobile.resolve(name: "editor_project", input: request).result(#"{"project":{"project":{"name":"Sample"}}}"#, host: .mobile)
        let decoder = JSONDecoder()
        let desktopContext = try decoder.decode(EditorCloudValue.self, from: Data(desktopResult.utf8))
        let mobileContext = try decoder.decode(EditorCloudValue.self, from: Data(mobileResult.utf8))
        #expect(desktopContext["project"] == mobileContext["project"])
        let list = try mobile.resolve(name: "editor_scene", input: ["action": "list", "arguments": ["scope": "project"]])
        let listResult = try list.result(#"{"scenes":["Scenes/Main.ascn"]}"#, host: .mobile)
        let scenes = try decoder.decode(EditorCloudValue.self, from: Data(listResult.utf8))
        #expect(scenes["scenes"].array == [["path": "Scenes/Main.ascn"]])
    }

    @Test @MainActor func groupedFileCallsValidateBeforeApprovalAndDispatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = "Sources/Game.ada"
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// original".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = try EditorCloudToolHost(projectURL: root, mobile: EditorMobileAgentToolService(projectURL: root)).tools()
        let rounds = Counter()
        let approvals = Counter()
        let service = EditorCloudAgentService(
            host: .mobile,
            connectionFactory: {
                EditorCloudAIConnection(toolContract: 2) { input, receive in
                    #expect(input["toolHost"].string == "mobile")
                    await rounds.increment()
                    if await rounds.value == 1 {
                        for (id, args) in [
                            ("invalid", #"{"action":"patch","arguments":{"path":"Sources/Game.ada","oldText":"original","newText":7}}"#),
                            ("read", #"{"action":"read","arguments":{"path":"Sources/Game.ada"}}"#),
                            ("patch", #"{"action":"patch","arguments":{"path":"Sources/Game.ada","oldText":"original","newText":"edited"}}"#),
                            ("missing", #"{"action":"delete","arguments":{"path":"Sources/Game.ada"}}"#),
                        ] {
                            try await receive(["type": "tool", "call": ["id": .string(id), "function": ["name": "editor_files", "arguments": .string(args)]]])
                        }
                    } else {
                        let results = input["messages"].array.filter { $0["role"].string == "tool" }
                        #expect(results.first { $0["toolCallID"].string == "read" }?["content"].string?.contains("original") == true)
                        try await receive(["type": "text", "text": "Done"])
                    }
                    try await receive(["type": "complete"])
                }
            },
            toolsFactory: { _ in tools }
        )
        _ = try await service.send(
            request(),
            onEvent: { event in
                if let permission = event.permission {
                    #expect(permission.summary.contains("editor_files/patch"))
                    await approvals.increment()
                    await service.resolvePermission(requestID: permission.id, optionID: "allow")
                }
            },
            onProjectFileChanged: { #expect($0 == path) }
        )
        #expect(await approvals.value == 1)
        #expect(try String(contentsOf: url, encoding: .utf8) == "// edited")
    }
    @Test func incompleteResponseNeverRunsToolsOrAutomaticallyRetries() async {
        let count = Counter()
        let service = EditorCloudAgentService(
            transportFactory: {
                { _, receive in
                    await count.increment()
                    try await receive(["type": "tool", "call": ["id": "call", "function": ["name": "editor_file_write", "arguments": "{}"]]])
                }
            }, toolsFactory: { _ in [] })
        await #expect(throws: (any Error).self) { _ = try await service.send(request(), onEvent: { _ in }, onProjectFileChanged: { _ in }) }
        #expect(await count.value == 1)
    }
    @Test func cancellingPendingPermissionNeverChangesTheProject() async throws {
        let gateway = Gateway()
        let count = Counter()
        let gate = Gate()
        let tool = EditorCloudAgentTool(
            name: "editor_file_write", definition: ["type": "function"], readOnly: false,
            invoke: { _ in
                await count.increment()
                return "Saved"
            })
        let service = EditorCloudAgentService(transportFactory: { { input, receive in try await gateway.respond(input, receive) } }, toolsFactory: { _ in [tool] })
        let task = Task {
            try await service.send(
                request(),
                onEvent: { event in
                    if event.permission != nil { await gate.open() }
                }, onProjectFileChanged: { _ in })
        }
        await gate.wait()
        await service.cancel(sessionID: "session")
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await count.value == 0)
        #expect(await gateway.operations.count == 1)
    }
    @Test @MainActor func nativeFileToolsCannotEscapeOrOverwriteExistingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let escapedName = "escape-" + UUID().uuidString + ".ada"
        let outside = root.deletingLastPathComponent().appendingPathComponent(escapedName)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let tools = try EditorCloudToolHost(projectURL: root, mobile: EditorMobileAgentToolService(projectURL: root)).tools()
        let write = try #require(tools.first { $0.name == "editor_file_write" })
        let read = try #require(tools.first { $0.name == "editor_file_read" })
        _ = try await write.invoke(["path": "Sources/Game.ada", "content": "original"])
        #expect(try await read.invoke(["path": "Sources/Game.ada"]) == "original")
        await #expect(throws: (any Error).self) { _ = try await write.invoke(["path": "Sources/Game.ada", "content": "overwrite"]) }
        await #expect(throws: (any Error).self) { _ = try await write.invoke(["path": "../escape.ada", "content": "escape"]) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Sources/link"), withDestinationURL: root.deletingLastPathComponent())
        await #expect(throws: (any Error).self) { _ = try await write.invoke(["path": .string("Sources/link/" + escapedName), "content": "escape"]) }
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(try await read.invoke(["path": "Sources/Game.ada"]) == "original")
    }
    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }
    private actor Gate {
        var opened = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { if !opened { await withCheckedContinuation { continuation = $0 } } }
        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }
    private actor Gateway {
        var operations: [String] = []
        let name: String
        let arguments: String
        init(name: String = "editor_file_write", arguments: String = #"{"path":"Sources/Game.ada"}"#) {
            self.name = name
            self.arguments = arguments
        }
        func respond(_ input: EditorCloudValue, _ receive: @escaping @Sendable (EditorCloudValue) async throws -> Void) async throws {
            let operation = try #require(input["operationID"].string)
            operations.append(operation)
            #expect(input["model"].string == "qwen/qwen3-coder-next")
            #expect(input["billingMode"].string == "ada")
            #expect(input["apiKey"] == .null)
            if operations.count == 1 {
                try await receive(["type": "tool", "call": ["id": "call", "function": ["name": .string(name), "arguments": .string(arguments)]]])
            } else {
                try await receive(["type": "text", "text": "Done"])
            }
            try await receive(["type": "complete"])
        }
    }
}
