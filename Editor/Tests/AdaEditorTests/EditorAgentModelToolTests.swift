import AdaEngine
import Foundation
import MCP
import Testing

@testable import AdaEditor

@MainActor
@Suite("Agent 3D authoring tools", .serialized)
struct EditorAgentModelToolTests {
    @Test("Both hosts advertise native model tools and lazily readable bundled knowledge")
    func inventory() async throws {
        let mobile = EditorMobileAgentTools.tools().map(\.name)
        let desktop = EditorAgentMCPTools.tools() + EditorAgentWorkspaceMCPTools.tools() + EditorAgentGravityMCPTools.tools()
            + EditorAgentWebTools.tools() + EditorAgentStoreTools.tools() + EditorAgentAuthoringMCPTools.tools()
        #expect(Set(desktop.map(\.name)).count == desktop.count)
        #expect(Set(mobile).count == mobile.count)
        let modelNames = ["editor.model.inspect", "editor.model.validate", "editor.model.import", "editor.model.material.edit", "editor.model.texture.assign"]
        for name in EditorAgentKnowledgeTools.tools().map(\.name) + modelNames {
            #expect(mobile.contains(name))
            #expect(desktop.contains { $0.name == name })
        }
        #expect(!EditorAgentAuthoringMCPTools.tools().contains { $0.name == "editor.scene.asset.assign" || $0.name == "editor.image.read" })
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let response = try await EditorAgentAuthoringMCPTools.execute(name: "editor.skills.read", arguments: ["id": "ada-3d-assets"], projectURL: root)
        let content = try payload(response)
        #expect((content["content"] as? String)?.contains("editor.model.inspect") == true)
        let mobileResult = await EditorMobileAgentToolService(projectURL: root).handle(name: "editor.skills.read", arguments: ["id": "ada-3d-assets"])
        #expect(mobileResult.ok, "\(mobileResult.payload)")
        #expect(MobileAgentHarnessSettings().prompt("Import a robot").contains("ada-3d-assets"))
        #expect(!MobileAgentHarnessSettings().prompt("Import a robot").contains("# Ada Studio 3D Assets"))
    }

    @Test("Native import reports transformed scene bounds and real geometry")
    func inspectTriangle() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try triangle(in: root.appendingPathComponent("Assets/Models"))
        let value = try await call(root, "editor.model.inspect", ["path": "Assets/Models/Triangle.gltf"])
        let counts = try #require(value["counts"] as? [String: Int])
        #expect(counts["vertices"] == 3)
        #expect(counts["triangles"] == 1)
        let bounds = try #require(value["bounds"] as? [String: [Double]])
        #expect(bounds["min"] == [3, 0, 0])
        #expect(bounds["max"] == [4, 1, 0])
        #expect(value["assetReference"] as? String == "@res://Models/Triangle.gltf")
        #expect(value["rendered"] as? Bool == false)
        #expect((value["dependencies"] as? [String]) == ["Assets/Models/Buffers/mesh.bin"])
        let response = try await EditorAgentAuthoringMCPTools.execute(name: "editor.model.inspect", arguments: ["path": "Assets/Models/Triangle.gltf"], projectURL: root)
        #expect(try payload(response)["counts"] as? [String: Int] == counts)
        let validation = try await call(root, "editor.asset.validate", ["path": "Assets/Models/Triangle.gltf"])
        #expect(validation["valid"] as? Bool == true)
    }

    @Test("Actual Blender GLB fixture exposes the skin and exact animation clip")
    func inspectSkeletalFixture() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ribbon(in: root.appendingPathComponent("Assets/Models"))
        let value = try await call(root, "editor.model.validate", ["path": .string("Assets/Models/" + source.lastPathComponent)])
        let clips = try #require(value["animations"] as? [[String: Any]])
        #expect(clips.first?["name"] as? String == "Bend")
        #expect((clips.first?["duration"] as? Double ?? 0) > 0)
        let skins = try #require(value["skins"] as? [[String: Any]])
        #expect(skins.first?["jointCount"] as? Int == 2)
        #expect(value["animationPlaybackVerified"] as? Bool == false)
    }

    @Test("Project-local import preserves dependencies and chooses a new bundle on repeat")
    func importBundle() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try triangle(in: root.appendingPathComponent("Downloads/Triangle"))
        let first = try await call(root, "editor.model.import", ["source": "Downloads/Triangle/Triangle.gltf", "destination": "Assets/Models"])
        let second = try await call(root, "editor.model.import", ["source": "Downloads/Triangle/Triangle.gltf", "destination": "Assets/Models"])
        let path = try #require(first["path"] as? String)
        #expect(path != second["path"] as? String)
        #expect(first["assetReference"] as? String == "@res://Models/Triangle/Triangle.gltf")
        let imported = try await NativeGLTFLoader().load(url: root.appendingPathComponent(path))
        #expect(imported.meshes.first?.primitives.first?.indices == [0, 1, 2])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Assets/Models/Triangle/Buffers/mesh.bin").path))
        let rejected = await EditorMobileAgentToolService(projectURL: root).handle(
            name: "editor.model.import", arguments: ["source": "Downloads/Triangle/Triangle.gltf", "destination": "Downloads/output"]
        )
        #expect(!rejected.ok)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Downloads/output").path))
    }

    @Test("PBR patches preserve GLB binary chunks and untouched fields; invalid patches preserve the file", arguments: [false, true])
    func materialPatch(binary: Bool) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = binary ? try ribbon(in: root.appendingPathComponent("Assets/Models")) : try triangle(in: root.appendingPathComponent("Assets/Models"))
        let path = "Assets/Models/" + source.lastPathComponent
        let before = try Data(contentsOf: source)
        let beforeJSON = try modelJSON(before, binary: binary)
        _ = try await call(root, "editor.model.material.edit", [
            "path": .string(path), "material": 0,
            "settingsJSON": "{\"baseColorFactor\":[0.8,0.1,0.2,1],\"metallicFactor\":0.25,\"roughnessFactor\":0.6}",
        ])
        let after = try Data(contentsOf: source)
        let afterJSON = try modelJSON(after, binary: binary)
        for key in ["meshes", "nodes", "animations", "skins", "buffers", "bufferViews", "accessors"] where beforeJSON[key] != nil {
            let old = try JSONSerialization.data(withJSONObject: #require(beforeJSON[key]), options: [.sortedKeys])
            let new = try JSONSerialization.data(withJSONObject: #require(afterJSON[key]), options: [.sortedKeys])
            #expect(old == new)
        }
        if binary {
            #expect(try EditorAgentModelTextureTools.decodeGLB(before).dropFirst().map(\.data) == EditorAgentModelTextureTools.decodeGLB(after).dropFirst().map(\.data))
        }
        let imported = try await NativeGLTFLoader().load(url: source)
        #expect(imported.materials.first?.metallicFactor == 0.25)
        #expect(imported.materials.first?.roughnessFactor == 0.6)
        for patch in ["{\"metallicFactor\":2}", "{\"doubleSided\":1}", "{\"alphaMode\":\"wrong\"}", "{\"unknown\":1}", "{\"baseColorFactor\":[1,0,0]}"] {
            let result = await EditorMobileAgentToolService(projectURL: root).handle(
                name: "editor.model.material.edit", arguments: ["path": .string(path), "material": 0, "settingsJSON": .string(patch)]
            )
            #expect(!result.ok)
            #expect(try Data(contentsOf: source) == after)
        }
    }

    @Test("Escaping/missing dependencies, cycles, unsupported extensions and excessive accessors are rejected")
    func rejectsBadModels() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try triangle(in: root.appendingPathComponent("Assets/Models"))
        let original = try String(contentsOf: source, encoding: .utf8)
        let tools = EditorMobileAgentToolService(projectURL: root)
        for uri in ["../../../secret.bin", "https://example.com/mesh.bin", "Buffers/missing.bin", "%2Ftmp%2Fsecret.bin"] {
            try original.replacingOccurrences(of: "Buffers/mesh.bin", with: uri).write(to: source, atomically: true, encoding: .utf8)
            let result = await tools.handle(name: "editor.model.validate", arguments: ["path": "Assets/Models/Triangle.gltf"])
            #expect(!result.ok, "\(uri)")
        }
        for fragment in ["\"extensionsRequired\":[\"KHR_draco_mesh_compression\"],", "\"nodes\":[{\"children\":[0]}],"] {
            let json = "{\"asset\":{\"version\":\"2.0\"}," + fragment + "\"scene\":0,\"scenes\":[{\"nodes\":[0]}]}"
            try json.write(to: source, atomically: true, encoding: .utf8)
            #expect(!(await tools.handle(name: "editor.model.validate", arguments: ["path": "Assets/Models/Triangle.gltf"])).ok)
        }
        try original.replacingOccurrences(of: "\"count\":3", with: "\"count\":2147483647").write(to: source, atomically: true, encoding: .utf8)
        #expect(!(await tools.handle(name: "editor.model.inspect", arguments: ["path": "Assets/Models/Triangle.gltf"])).ok)
        var repeated = try #require(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        repeated["accessors"] = [["componentType": 5126, "type": "VEC3", "count": 1_000_000]]
        repeated["meshes"] = [["primitives": Array(repeating: ["attributes": ["POSITION": 0]], count: 3)]]
        try JSONSerialization.data(withJSONObject: repeated).write(to: source)
        let budget = await tools.handle(name: "editor.model.inspect", arguments: ["path": "Assets/Models/Triangle.gltf"])
        #expect(!budget.ok)
        #expect(budget.payload.contains("inspection budget"))
        try original.write(to: source, atomically: true, encoding: .utf8)
        let outside = root.appendingPathComponent("Sources/secret.bin")
        try Data(repeating: 0, count: 42).write(to: outside)
        let buffer = root.appendingPathComponent("Assets/Models/Buffers/mesh.bin")
        try FileManager.default.removeItem(at: buffer)
        try FileManager.default.createSymbolicLink(at: buffer, withDestinationURL: outside)
        #expect(!(await tools.handle(name: "editor.model.validate", arguments: ["path": "Assets/Models/Triangle.gltf"])).ok)
        #expect(try Data(contentsOf: outside) == Data(repeating: 0, count: 42))
    }

    @Test("Desktop dispatch uses the open project and rejects dirty target aliases")
    func desktopDispatch() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try triangle(in: root.appendingPathComponent("Assets/Models"))
        let editor = EditorViewModel(project: EditorProjectReference(name: "3D Tools", path: root.path))
        EditorAgentMCPTools.shared.activate(editor)
        defer { EditorAgentMCPTools.shared.deactivate(editor) }
        let context = try #require(EditorAgentMCPTools.shared.handle(name: "editor.project.context", arguments: [:]))
        #expect(try payload(context)["model3D"] != nil)
        let response = try #require(await EditorAgentAuthoringMCPTools.handle(name: "editor.model.inspect", arguments: ["path": "Assets/Models/Triangle.gltf"]))
        #expect(response.isError != true)
        #expect(try payload(response)["valid"] as? Bool == true)
        let document = EditorTextDocument(
            id: "dirty-model",
            title: file.lastPathComponent,
            relativePath: "Assets/Models/Triangle.gltf",
            absolutePath: file.path,
            language: .yaml,
            content: "unsaved model",
            isDirty: true
        )
        editor.workbench.open(.text(document))
        let before = try Data(contentsOf: file)
        let rejected = try #require(await EditorAgentAuthoringMCPTools.handle(name: "editor.model.material.edit", arguments: [
            "path": "Assets/Models/../Models/Triangle.gltf", "material": 0, "settingsJSON": "{\"roughnessFactor\":0.2}",
        ]))
        #expect(rejected.isError == true)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("Image decoding is part of native model validation")
    func textureDependencies() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try triangle(in: root.appendingPathComponent("Assets/Models"))
        _ = try await call(root, "editor.texture.render", ["path": "Assets/Models/body.png", "specJSON": "{\"width\":8,\"height\":8}"])
        _ = try await call(root, "editor.model.texture.assign", ["path": "Assets/Models/Triangle.gltf", "texture": "Assets/Models/body.png", "channel": "baseColor"])
        let value = try await call(root, "editor.model.validate", ["path": "Assets/Models/Triangle.gltf"])
        #expect((value["images"] as? [[String: Any]])?.first?["path"] as? String == "Assets/Models/body.png")
        try Data("invalid PNG".utf8).write(to: root.appendingPathComponent("Assets/Models/body.png"))
        let result = await EditorMobileAgentToolService(projectURL: root).handle(name: "editor.model.validate", arguments: ["path": "Assets/Models/Triangle.gltf"])
        #expect(!result.ok)
    }

    private func call(_ root: URL, _ name: String, _ arguments: [String: Value]) async throws -> [String: Any] {
        let result = await EditorMobileAgentToolService(projectURL: root).handle(name: name, arguments: arguments)
        #expect(result.ok, "\(result.payload)")
        return try #require(JSONSerialization.jsonObject(with: Data(result.payload.utf8)) as? [String: Any])
    }

    private func payload(_ result: CallTool.Result) throws -> [String: Any] {
        guard case let .text(text, _, _)? = result.content.first else { throw CocoaError(.fileReadCorruptFile) }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func modelJSON(_ data: Data, binary: Bool) throws -> [String: Any] {
        let json = binary ? try #require(EditorAgentModelTextureTools.decodeGLB(data).first?.data) : data
        return try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentModelTools-\(UUID())")
        for path in ["Assets/Models", "Sources", "Downloads"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true) }
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "3D Tools", buildSystem: .adaScript), at: root)
        return root
    }

    private func ribbon(in root: URL) throws -> URL {
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try EditorModelAssetImporter.copy(engine.appendingPathComponent("Tests/AdaAssetsTests/Fixtures/TwoBoneRibbon.glb"), to: root)
    }

    private func triangle(in root: URL) throws -> URL {
        let buffers = root.appendingPathComponent("Buffers")
        try FileManager.default.createDirectory(at: buffers, withIntermediateDirectories: true)
        var data = Data()
        for value: Float in [0, 0, 0, 1, 0, 0, 0, 1, 0] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: [0, 0, 1, 0, 2, 0])
        try data.write(to: buffers.appendingPathComponent("mesh.bin"))
        let source = root.appendingPathComponent("Triangle.gltf")
        try """
        {"asset":{"version":"2.0"},"buffers":[{"uri":"Buffers/mesh.bin","byteLength":42}],
        "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":6}],
        "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},{"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}],
        "materials":[{"name":"Body","pbrMetallicRoughness":{"metallicFactor":0,"roughnessFactor":0.7}}],
        "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1,"material":0}]}],
        "nodes":[{"name":"Offset mesh","mesh":0,"translation":[3,0,0]}],"scenes":[{"nodes":[0]}],"scene":0}
        """.write(to: source, atomically: true, encoding: .utf8)
        return source
    }
}
