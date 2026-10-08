import AdaEngine
import Foundation
import MCP
import Testing
import Yams

@testable import AdaEditor

#if canImport(CoreGraphics) && canImport(ImageIO)
@MainActor
@Suite("Agent image and asset authoring", .serialized)
struct EditorAgentAssetToolTests {
    @Test("Real procedural PNGs pack into the native named atlas with inspectable UV regions")
    func texturesAndAtlas() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = EditorMobileAgentToolService(projectURL: root)
        _ = try await call(tools, "editor.texture.render", ["path": "Assets/Gfx/a.png", "specJSON": "{\"width\":32,\"height\":32,\"pattern\":\"checker\",\"cellSize\":16}"])
        _ = try await call(tools, "editor.texture.render", ["path": "Assets/Gfx/b.png", "specJSON": "{\"width\":16,\"height\":16,\"pattern\":\"normal\"}"])
        let first = try Image(contentsOf: root.appendingPathComponent("Assets/Gfx/a.png"))
        #expect(first.width == 32)
        #expect(first.getPixel(x: 0, y: 0).red > 0.99)
        #expect(first.getPixel(x: 16, y: 0).red < 0.2)
        let spec = "{\"images\":[{\"path\":\"a.png\",\"key\":\"player\"},{\"path\":\"b.png\",\"key\":\"normal\"}],\"padding\":2,\"extrude\":1,\"sampler\":\"nearest\"}"
        let written = try await call(tools, "editor.atlas.write", ["path": "Assets/Gfx/game.atlas", "descriptorJSON": .string(spec)])
        #expect((written["regions"] as? [String: Any])?.count == 2)
        _ = try await call(tools, "editor.atlas.pack", ["path": "Assets/Gfx/game.atlas", "previewPath": "Assets/Gfx/packed.png"])
        let descriptor = try YAMLDecoder().decode(NamedTextureAtlas.Descriptor.self, from: String(contentsOf: root.appendingPathComponent("Assets/Gfx/game.atlas"), encoding: .utf8))
        #expect(descriptor.images.count == 2)
        let preview = try Image(contentsOf: root.appendingPathComponent("Assets/Gfx/packed.png"))
        #expect(preview.width > 32)
        let regions = try #require(written["regions"] as? [String: Any])
        #expect(regions["player"] != nil)
        let before = try Data(contentsOf: root.appendingPathComponent("Assets/Gfx/a.png"))
        #expect(!(await tools.handle(name: "editor.texture.render", arguments: ["path": "Assets/Gfx/a.png", "specJSON": "{}"])).ok)
        #expect(try Data(contentsOf: root.appendingPathComponent("Assets/Gfx/a.png")) == before)
    }

    @Test("Tile sources, animation, layered maps and reference protection use native files")
    func tileWorkflow() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = EditorMobileAgentToolService(projectURL: root)
        _ = try await call(tools, "editor.texture.render", ["path": "Assets/Tiles/sheet.png", "specJSON": "{\"width\":64,\"height\":32,\"pattern\":\"checker\",\"cellSize\":16}"])
        let source = try await call(tools, "editor.tileset.create", ["path": "Assets/Tiles/terrain.tileset", "image": "Assets/Tiles/sheet.png", "tileWidth": 16, "tileHeight": 16])
        #expect((source["palette"] as? [[String: Any]])?.count == 8)
        _ = try await call(
            tools,
            "editor.tileset.edit",
            ["path": "Assets/Tiles/terrain.tileset", "operationsJSON": "[{\"op\":\"animate\",\"sourceID\":1,\"x\":0,\"y\":0,\"frames\":2,\"duration\":0.2}]"]
        )
        let mapJSON = "{\"atlasColors\":[],\"cells\":[[0,0,0],[1,0,7]],\"tileSetReference\":\"@res://Tiles/terrain.tileset\"}"
        _ = try await call(tools, "editor.tilemap.write", ["path": "Assets/Tiles/level.tilemap", "resourceJSON": .string(mapJSON)])
        _ = try await call(
            tools,
            "editor.tilemap.edit",
            [
                "path": "Assets/Tiles/level.tilemap",
                "operationsJSON":
                    "[{\"op\":\"fill\",\"x\":0,\"y\":0,\"width\":4,\"height\":2,\"tile\":3},{\"op\":\"addLayer\",\"name\":\"Decor\"},{\"op\":\"paint\",\"layer\":1,\"x\":0,\"y\":0,\"tile\":7}]",
            ]
        )
        let map = try EditorTileMapResource.read(from: root.appendingPathComponent("Assets/Tiles/level.tilemap"))
        #expect(map.tileSetTiles?.count == 8)
        #expect(map.effectiveLayers.count == 2)
        #expect(map.effectiveLayers[0].cells.count == 8)
        #expect(map.effectiveLayers[1].cells == [[0, 0, 7]])
        let tilesetURL = root.appendingPathComponent("Assets/Tiles/terrain.tileset")
        let original = try Data(contentsOf: tilesetURL)
        let rejected = await tools.handle(name: "editor.tileset.edit", arguments: ["path": "Assets/Tiles/terrain.tileset", "operationsJSON": "[{\"op\":\"remove\",\"x\":0,\"y\":0}]"])
        #expect(!rejected.ok)
        #expect(try Data(contentsOf: tilesetURL) == original)
        _ = try await call(tools, "editor.asset.validate", ["path": "Assets/Tiles/level.tilemap"])
    }

    @Test("Material texture assignment preserves glTF geometry and GLB binary chunks")
    func modelTextures() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = EditorMobileAgentToolService(projectURL: root)
        _ = try await call(tools, "editor.texture.render", ["path": "Assets/Models/color.png", "specJSON": "{\"width\":8,\"height\":8}"])
        let source: [String: Any] = ["asset": ["version": "2.0"], "materials": [["name": "Body"]], "meshes": [["primitives": [["attributes": ["POSITION": 0]]]]]]
        let json = try JSONSerialization.data(withJSONObject: source)
        try json.write(to: root.appendingPathComponent("Assets/Models/test.gltf"))
        let bytes = Data([0, 1, 2, 3, 4, 5, 6, 7])
        let glb = try EditorAgentModelTextureTools.encodeGLB(json: json, preserving: [.init(type: 0x004E_4942, data: bytes)])
        try glb.write(to: root.appendingPathComponent("Assets/Models/test.glb"))
        for ext in ["gltf", "glb"] {
            _ = try await call(tools, "editor.model.texture.assign", ["path": .string("Assets/Models/test.\(ext)"), "texture": "Assets/Models/color.png", "channel": "baseColor"])
            let data = try Data(contentsOf: root.appendingPathComponent("Assets/Models/test.\(ext)"))
            let body = ext == "glb" ? try #require(EditorAgentModelTextureTools.decodeGLB(data).first?.data) : data
            let result = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let outputMeshes = try #require(result["meshes"])
            let originalMeshes = try #require(source["meshes"])
            #expect(try JSONSerialization.data(withJSONObject: outputMeshes, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: originalMeshes, options: [.sortedKeys]))
            #expect((result["images"] as? [[String: Any]])?.first?["uri"] as? String == "color.png")
            if ext == "glb" { #expect(try EditorAgentModelTextureTools.decodeGLB(data).last?.data == bytes) }
        }
    }

    @Test("Image analysis receives decoded pixels and image generation writes real PNG bytes")
    func imageModelTools() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try EditorImageAttachment.encodePNG(Image(width: 12, height: 8, color: .white))
        let tools = EditorMobileAgentToolService(
            projectURL: root,
            imageCredentials: FixtureCredentials(),
            imageClient: FixtureImageClient(png: png),
            imageAnalyzer: { urls, question in
                #expect(question == "Describe the texture")
                let data = try EditorImageAttachment.pngData(at: urls[0])
                #expect(!data.isEmpty)
                return "White texture"
            }
        )
        _ = try await call(tools, "editor.image.generate", ["prompt": "White texture", "destination": "Assets/Models/generated.png"])
        let image = try Image(contentsOf: root.appendingPathComponent("Assets/Models/generated.png"))
        #expect(image.width == 12)
        let answer = try await call(tools, "editor.image.read", ["path": "Assets/Models/generated.png", "question": "Describe the texture"])
        #expect(answer["analysis"] as? String == "White texture")
    }

    @Test("Malformed resources and escaping image paths never replace valid files")
    func rejectsBadAssets() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = EditorMobileAgentToolService(projectURL: root)
        for path in ["../escape.png", "Sources/no.png", "/tmp/no.png"] {
            #expect(!(await tools.handle(name: "editor.texture.render", arguments: ["path": .string(path), "specJSON": "{}"])).ok)
        }
        #expect(!(await tools.handle(name: "editor.texture.render", arguments: ["path": "Assets/Models/no.png", "specJSON": "{\"width\":1e100}"])).ok)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Assets/Models/no.png").path))
    }

    private func call(_ service: EditorMobileAgentToolService, _ name: String, _ arguments: [String: Value]) async throws -> [String: Any] {
        let result = await service.handle(name: name, arguments: arguments)
        #expect(result.ok, "\(result.payload)")
        return try #require(JSONSerialization.jsonObject(with: Data(result.payload.utf8)) as? [String: Any])
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentAssetTools-\(UUID())")
        for path in ["Assets/Gfx", "Assets/Tiles", "Assets/Models", "Sources"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        var project = ProjectSystem.defaultProject(projectName: "Assets", buildSystem: .adaScript)
        project.ai.imageGeneration.enabled = true
        try ProjectSystem.saveProject(project, at: root)
        return root
    }
}

private struct FixtureCredentials: EditorImageCredentialProviding {
    func apiKey() async throws -> String { "fixture-image-key" }
}

private struct FixtureImageClient: EditorImageGenerationHTTPClient {
    let png: Data
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #expect(request.url?.path == "/v1/images/generations")
        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        #expect(body?["model"] as? String == "gpt-image-2")
        let data = try JSONSerialization.data(withJSONObject: ["data": [["b64_json": png.base64EncodedString()]]])
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (data, response)
    }
}
#endif
