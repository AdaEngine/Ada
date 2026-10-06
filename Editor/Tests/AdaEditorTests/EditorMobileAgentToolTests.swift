@_spi(Internal) @testable import AdaRender
import Foundation
import MCP
import Testing

@testable import AdaEditor
import AdaEngine

@MainActor
@Suite("Mobile agent tools", .serialized)
struct EditorMobileAgentToolTests {
    @Test("Embedded LSP reports current files, repairs and cross-file definitions")
    func languageFeedback() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = EditorMobileAgentToolService(projectURL: root)
        let source = root.appendingPathComponent("Sources/Game.ada")
        try "@system class Broken {".write(to: source, atomically: true, encoding: .utf8)
        let diagnostics = try await call(service, "editor.gravity.diagnostics")
        #expect(!(diagnostics["diagnostics"] as? [[String: Any]] ?? []).isEmpty)
        let brokenBuild = service.build()
        #expect(!brokenBuild.ok)
        #expect(brokenBuild.payload.contains("error"))
        try "class Helper { func value() { return 1; } }".write(to: root.appendingPathComponent("Sources/Helper.ada"), atomically: true, encoding: .utf8)
        try "var value = Helper();".write(to: source, atomically: true, encoding: .utf8)
        let definition = try await call(service, "editor.gravity.definition", ["path": "Sources/Game.ada", "line": 0, "character": 14])
        let targets = try #require(definition["targets"] as? [[String: Any]])
        #expect(targets.first?["path"] as? String == "Sources/Helper.ada")
        let completion = try await call(service, "editor.gravity.completion", ["path": "Sources/Game.ada", "line": 0, "character": 14])
        #expect(!(completion["items"] as? [[String: Any]] ?? []).isEmpty)
        let hover = try await call(service, "editor.gravity.hover", ["path": "Sources/Game.ada", "line": 0, "character": 14])
        #expect(hover["contents"] is String)
        try "// Repaired source".write(to: source, atomically: true, encoding: .utf8)
        let repaired = try await call(service, "editor.gravity.diagnostics", ["path": "Sources/Game.ada"])
        #expect((repaired["diagnostics"] as? [[String: Any]])?.isEmpty == true)
        #expect(service.build().ok)
    }

    @Test("All scene validation rejects an invalid level outside the startup scene")
    func validatesLaterScene() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var scene = EditorSceneModel.default(projectName: "Later")
        let entity = scene.addEntity(name: "Enemy")
        let index = try #require(scene.entities.firstIndex { $0.id == entity.id })
        scene.entities[index].components["Game.UnknownEnemy"] = [:]
        try scene.encodedYAML().write(to: root.appendingPathComponent("Assets/Scenes/Later.ascn"), atomically: true, encoding: .utf8)
        let service = EditorMobileAgentToolService(projectURL: root)
        let result = service.build()
        #expect(!result.ok)
        #expect(result.payload.contains("Later.ascn"))
        #expect(result.payload.contains("Game.UnknownEnemy"))
    }

    @Test("Device documentation, API, component payloads and complete examples are readable offline")
    func knowledge() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = EditorMobileAgentToolService(projectURL: root)
        let docs = try await call(service, "editor.docs.search", ["query": "AdaScript"])
        #expect(!(docs["articles"] as? [[String: Any]] ?? []).isEmpty)
        let article = try await call(service, "editor.docs.read", ["id": "AdaScripting"])
        #expect((article["content"] as? String)?.contains("@query") == true)
        let api = try await call(service, "editor.api.describe", ["query": "Input"])
        #expect(String(describing: api).contains("getActionStrength"))
        let components = try await call(service, "editor.components.describe", ["query": "Transform"])
        #expect(String(describing: components).contains("defaultPayload"))
        let list = try await call(service, "editor.examples.list")
        #expect((list["examples"] as? [[String: Any]])?.count == 3)
        let example = try await call(service, "editor.examples.read", ["id": "keyboard-movement"])
        #expect((example["files"] as? [String: String])?["Sources/Game.ada"]?.contains("@res var input") == true)
    }

    @Test("Bundled projects compile, load their scenes and execute real systems")
    func examplesRun() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        for example in EditorAgentKnowledge.examples {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentExample-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            for (path, text) in example.files {
                let file = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: file, atomically: true, encoding: .utf8)
            }
            let service = EditorMobileAgentToolService(projectURL: root)
            defer { service.finish() }
            let build = service.build()
            #expect(build.ok, "\(build.payload)")
            _ = try await call(service, "editor.runtime.start")
            let stepped = try await call(service, "editor.runtime.step", ["frames": 6, "keys": .array(["d"])])
            #expect((stepped["diagnostics"] as? [String])?.isEmpty == true)
            #expect(stepped["frame"] as? Int == 6)
            let entities = try #require(stepped["entities"] as? [[String: Any]])
            if example.id == "keyboard-movement" {
                let player = try #require(entities.first { $0["name"] as? String == "Player" })
                let position = try #require(player["position"] as? [Double])
                #expect(abs(position[0] - 12) < 0.01)
                let released = try await call(service, "editor.runtime.step", ["frames": 6, "keys": .array([])])
                let after = try #require((released["entities"] as? [[String: Any]])?.first { $0["name"] as? String == "Player" })
                #expect(abs(((after["position"] as? [Double])?.first ?? -1) - 12) < 0.01)
            } else if example.id == "basic-3d-scene" {
                #expect(entities.contains { $0["name"] as? String == "Cube" })
                #expect(stepped["rendered"] as? Bool == false)
            } else {
                #expect(String(describing: entities).contains("Counter"))
                #expect(String(describing: entities).contains("6"))
            }
        }
    }

    @Test("Runtime errors survive tool results and can be read by output cursor")
    func runtimeErrors() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        @system class Failing {
            func update(context) { assert(false, "agent-runtime-probe"); }
        }
        """.write(to: root.appendingPathComponent("Sources/Game.ada"), atomically: true, encoding: .utf8)
        let service = EditorMobileAgentToolService(projectURL: root, liveDiagnostics: { ["visible Play failure"] })
        defer { service.finish() }
        _ = try await call(service, "editor.runtime.start")
        let value = await service.handle(name: "editor.runtime.step", arguments: ["frames": 1])
        #expect(!value.ok)
        #expect(value.payload.contains("agent-runtime-probe"))
        let completion = await service.validatePrototype()
        #expect(!completion.ok)
        #expect(completion.payload.contains("agent-runtime-probe"))
        let output = try await call(service, "editor.output.read")
        #expect(String(describing: output).contains("agent-runtime-probe"))
        #expect((output["playDiagnostics"] as? [String]) == ["visible Play failure"])
        let cursor = try #require(output["nextCursor"] as? Int)
        let next = try await call(service, "editor.output.read", ["after": .int(cursor)])
        #expect((next["entries"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test("Schema failures include the source path and detailed explanation")
    func schemaErrors() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "@component struct Counter { @export var value = 0; }".write(to: root.appendingPathComponent("Sources/Game.ada"), atomically: true, encoding: .utf8)
        let result = EditorMobileAgentToolService(projectURL: root).build()
        #expect(!result.ok)
        #expect(result.payload.contains("Game.ada"))
        #expect(result.payload.contains("schema"))
        #expect(!result.payload.contains("error 3"))
    }

    @Test("Configuration writes are validated and invalid patches preserve the original bytes")
    func projectConfiguration() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = EditorMobileAgentToolService(projectURL: root)
        let file = ProjectSystem.metadataURL(forProjectAt: root)
        let original = try Data(contentsOf: file)
        for patch in [
            "{\"paths\":{\"sources\":\"/tmp\"}}", "{\"runtime\":{\"entry\":{\"scene\":\"../Outside.ascn\"}}}", "{\"runtime\":{\"plugins\":{\"presetVersion\":99,\"preset\":\"ui\"}}}",
        ] {
            let result = await service.handle(name: "editor.project.configure", arguments: ["settingsJSON": .string(patch)])
            #expect(!result.ok)
            #expect(try Data(contentsOf: file) == original)
        }
        // Encode actual engine values instead of depending on a guessed enum wire format.
        let actions = [InputAction(name: "Jump", bindings: [.key(.space)])]
        let encoded = try JSONEncoder().encode(actions)
        let settings = "{\"inputActions\":\(try #require(String(data: encoded, encoding: .utf8)))}"
        _ = try await call(service, "editor.project.configure", ["settingsJSON": .string(settings)])
        #expect(try ProjectSystem.loadProject(at: root).inputActions == actions)
        #expect(try Data(contentsOf: file) != original)
    }

    @Test("LSP rejects traversal, symlink escapes and invalid positions")
    func scopedPaths() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Sources/escape.ada"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        let service = EditorMobileAgentToolService(projectURL: root)
        for path in ["../escape.ada", "/etc/passwd", "Sources/escape.ada"] {
            #expect(!(await service.handle(name: "editor.gravity.diagnostics", arguments: ["path": .string(path)])).ok)
        }
        #expect(!(await service.handle(name: "editor.gravity.hover", arguments: ["path": "Sources/Game.ada", "line": 900, "character": 0])).ok)
        #expect(!(await service.handle(name: "editor.runtime.step", arguments: ["frames": 0])).ok)
    }

    @Test("Nullable optional arguments work and invalid numeric arguments return errors")
    func argumentValidation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = EditorMobileAgentToolService(projectURL: root)
        defer { service.finish() }
        _ = try await call(service, "editor.runtime.start")
        let step = try await call(service, "editor.runtime.step", ["frames": .null, "deltaTime": .null, "keys": .null])
        #expect(step["frame"] as? Int == 1)
        for value in [Value.double(1e100), .double(.infinity), .double(1.5), .string("one")] {
            #expect(!(await service.handle(name: "editor.runtime.step", arguments: ["frames": value])).ok)
            #expect(!(await service.handle(name: "editor.output.read", arguments: ["after": value])).ok)
        }
    }

    private func call(_ service: EditorMobileAgentToolService, _ name: String, _ arguments: [String: Value] = [:]) async throws -> [String: Any] {
        let result = await service.handle(name: name, arguments: arguments)
        #expect(result.ok, "\(result.payload)")
        return try #require(JSONSerialization.jsonObject(with: Data(result.payload.utf8)) as? [String: Any])
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MobileAgentTools-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets/Scenes"), withIntermediateDirectories: true)
        var project = ProjectSystem.defaultProject(projectName: "Tools", buildSystem: .adaScript)
        project.runtime.entry = .init(scene: SceneDocumentFormat.defaultScenePath)
        project.runtime.plugins.preset = .ui
        try ProjectSystem.saveProject(project, at: root)
        try "// Initial source".write(to: root.appendingPathComponent("Sources/Game.ada"), atomically: true, encoding: .utf8)
        var scene = EditorSceneModel.default(projectName: "Tools")
        scene.entities = []
        try scene.encodedYAML().write(to: root.appendingPathComponent(SceneDocumentFormat.defaultScenePath), atomically: true, encoding: .utf8)
        return root
    }
}
