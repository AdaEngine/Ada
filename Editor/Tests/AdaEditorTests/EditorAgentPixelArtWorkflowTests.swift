import AdaAssets
import AdaEngine
import AdaScripting
import AdaSprite
import Foundation
import MCP
import Testing

@testable import AdaEditor

@MainActor
@Suite("Agent pixel art workflow tools", .serialized)
struct EditorAgentPixelArtWorkflowTests {
    private static let strip = """
        func build(sprite) {
            sprite.size(8, 8, 3);
            sprite.palettePreset("pico-8");
            var i = 0;
            while (i < 3) {
                sprite.frame(i);
                sprite.fill(8);
                sprite.pixel(i, i, 7);
                i = i + 1;
            }
            sprite.frameDuration(1, 80);
            sprite.tag("walk", 0, 2);
        }
        """

    @Test("Extracts a palette from a user image and renders with it through user: presets")
    func paletteExtractRoundTrip() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = EditorMobileAgentToolService(projectURL: root)
        // 2x2 reference: red, red, green, transparent.
        let rgba: [UInt8] = [200, 10, 10, 255, 200, 10, 10, 255, 10, 200, 10, 255, 0, 0, 0, 0]
        let png = try PNGWriter().encode(width: 2, height: 2, rgba: rgba)
        try png.write(to: root.appendingPathComponent("Assets/Sprites/reference.png"))

        let extracted = await service.handle(
            name: "editor.palette.extract",
            arguments: ["image": "Assets/Sprites/reference.png", "name": "brand", "maxColors": 8]
        )
        #expect(extracted.ok, "\(extracted.payload)")
        let payload = try #require(JSONSerialization.jsonObject(with: Data(extracted.payload.utf8)) as? [String: Any])
        #expect(payload["colors"] as? [String] == ["#C80A0A", "#0AC80A"])
        #expect(payload["path"] as? String == ".ada/workspace/pixel-art/palettes/brand.json")
        let paletteURL = root.appendingPathComponent(".ada/workspace/pixel-art/palettes/brand.json")
        #expect(FileManager.default.fileExists(atPath: paletteURL.path))

        let generated = await service.handle(
            name: "editor.sprite.generate",
            arguments: [
                "destination": "Assets/Sprites/branded.png",
                "source": .string("func build(sprite) { sprite.size(4, 4); sprite.palettePreset(\"user:brand\"); sprite.fill(1); }"),
            ]
        )
        #expect(generated.ok, "\(generated.payload)")
        let image = try Image(contentsOf: root.appendingPathComponent("Assets/Sprites/branded.png"))
        #expect(Array(image.data.prefix(4)) == [200, 10, 10, 255])

        // Never overwrites an existing palette, and rejects unsafe names and paths.
        #expect(!(await service.handle(name: "editor.palette.extract", arguments: ["image": "Assets/Sprites/reference.png", "name": "brand"])).ok)
        #expect(!(await service.handle(name: "editor.palette.extract", arguments: ["image": "../outside.png", "name": "other"])).ok)
        #expect(!(await service.handle(name: "editor.palette.extract", arguments: ["image": "Assets/Sprites/missing.png", "name": "other"])).ok)
        #expect(!(await service.handle(name: "editor.palette.extract", arguments: ["image": "Assets/Sprites/reference.png", "name": "../evil"])).ok)
    }

    @Test("Frame scripts write a strip PNG plus an Aseprite-compatible sidecar with the recipe path")
    func generatesStripWithSidecar() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = EditorMobileAgentToolService(projectURL: root)
        let result = await service.handle(
            name: "editor.sprite.generate",
            arguments: [
                "destination": "Assets/Sprites/slime.png",
                "source": .string(Self.strip),
                "recipe": .string(".ada/workspace/pixel-art/slime.adas"),
            ]
        )
        #expect(result.ok, "\(result.payload)")
        let payload = try #require(JSONSerialization.jsonObject(with: Data(result.payload.utf8)) as? [String: Any])
        #expect(payload["frames"] as? Int == 3)
        #expect(payload["frameWidth"] as? Int == 8)
        #expect(payload["tags"] as? [String] == ["walk"])
        #expect(payload["sheet"] as? String == "Assets/Sprites/slime.sheet.json")

        let image = try Image(contentsOf: root.appendingPathComponent("Assets/Sprites/slime.png"))
        #expect(image.width == 24 && image.height == 8)
        let sidecar = try Data(contentsOf: root.appendingPathComponent("Assets/Sprites/slime.sheet.json"))
        let sheet = try AsepriteSheet(data: sidecar)
        #expect(sheet.clips.map(\.name) == ["walk"])
        #expect(sheet.clips[0].frames.count == 3)
        let region = try #require(sheet.clips[0].frames[0].region)
        #expect(region.origin.x == 0 && region.origin.y == 0 && region.size.width == 8 && region.size.height == 8)
        let meta = try #require(JSONSerialization.jsonObject(with: sidecar) as? [String: Any])
        #expect((meta["meta"] as? [String: Any])?["recipe"] as? String == ".ada/workspace/pixel-art/slime.adas")

        let invalid = await service.handle(
            name: "editor.sprite.generate",
            arguments: ["destination": "Assets/Sprites/invalid.png", "source": .string(Self.strip), "recipe": "../outside.adas"]
        )
        #expect(!invalid.ok)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Assets/Sprites/invalid.png").path))

        let occupied = root.appendingPathComponent("Assets/Sprites/occupied.sheet.json")
        let existing = Data("existing metadata".utf8)
        try existing.write(to: occupied)
        let collision = await service.handle(
            name: "editor.sprite.generate",
            arguments: ["destination": "Assets/Sprites/occupied.png", "source": .string(Self.strip)]
        )
        #expect(!collision.ok)
        #expect(try Data(contentsOf: occupied) == existing)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Assets/Sprites/occupied.png").path))

        // Flat sprites keep the old contract: no sidecar, same summary shape as before.
        let flat = await service.handle(
            name: "editor.sprite.generate",
            arguments: ["destination": "Assets/Sprites/rock.png", "source": .string("func build(sprite) { sprite.size(4, 4); sprite.fill(1); }")]
        )
        #expect(flat.ok, "\(flat.payload)")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Assets/Sprites/rock.sheet.json").path))
    }

    @Test("sprite.gif renders the strip from its sidecar at an integer scale and never overwrites")
    func spriteGifFromSidecar() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = EditorMobileAgentToolService(projectURL: root)
        _ = await service.handle(
            name: "editor.sprite.generate",
            arguments: ["destination": "Assets/Sprites/slime.png", "source": .string(Self.strip)]
        )
        let gif = await service.handle(
            name: "editor.sprite.gif",
            arguments: ["path": "Assets/Sprites/slime.png", "destination": "Assets/Sprites/slime.gif", "scale": 4]
        )
        #expect(gif.ok, "\(gif.payload)")
        let payload = try #require(JSONSerialization.jsonObject(with: Data(gif.payload.utf8)) as? [String: Any])
        #expect(payload["frames"] as? Int == 3)
        #expect(payload["size"] as? [Int] == [32, 32])
        let bytes = try Data(contentsOf: root.appendingPathComponent("Assets/Sprites/slime.gif"))
        let decoded = try GIFReader().decode(bytes)
        #expect(decoded.width == 32 && decoded.height == 32)
        #expect(decoded.loops)
        #expect(decoded.frames.map(\.delayMilliseconds) == [100, 80, 100])
        for (index, frame) in decoded.frames.enumerated() {
            let highlightedPixel = (index * 4) * decoded.width + index * 4
            let color = decoded.palette[Int(frame.indices[highlightedPixel])]
            #expect(color == PixelColor(red: 194, green: 195, blue: 199))
            let background = decoded.palette[Int(frame.indices[31])]
            #expect(background == PixelColor(red: 255, green: 241, blue: 232))
        }
        #expect(!(await service.handle(name: "editor.sprite.gif", arguments: ["path": "Assets/Sprites/slime.png", "destination": "Assets/Sprites/slime.gif"])).ok)

        let previewPath = ".ada/workspace/pixel-art/slime.gif"
        let preview = await service.handle(
            name: "editor.sprite.gif",
            arguments: ["path": "Assets/Sprites/slime.png", "destination": .string(previewPath), "firstFrame": 1, "lastFrame": 2]
        )
        try #require(preview.ok, "\(preview.payload)")
        let range = try GIFReader().decode(Data(contentsOf: root.appendingPathComponent(previewPath)))
        #expect(range.width == decoded.width && range.height == decoded.height)
        #expect(range.frames.map(\.delayMilliseconds) == [80, 100])
        let expectedPixels = decoded.frames[1...2].map { $0.indices.map { decoded.palette[Int($0)] } }
        let rangePixels = range.frames.map { $0.indices.map { range.palette[Int($0)] } }
        #expect(rangePixels == expectedPixels)
    }

    @Test("The agent can write, read and patch a saved sprite recipe")
    func editsSavedRecipe() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = EditorCloudToolHost(projectURL: root, mobile: EditorMobileAgentToolService(projectURL: root))
        let tools = try host.tools()
        let write = try #require(tools.first { $0.name == "editor_file_write" })
        let read = try #require(tools.first { $0.name == "editor_file_read" })
        let patch = try #require(tools.first { $0.name == "editor_file_patch" })
        let path = EditorCloudValue.string(".ada/workspace/pixel-art/slime.adas")
        _ = try await write.invoke(["path": path, "content": .string(Self.strip)])
        #expect(try await read.invoke(["path": path]) == Self.strip)
        _ = try await patch.invoke(["path": path, "oldText": "sprite.fill(8)", "newText": "sprite.fill(9)"])
        #expect(try await read.invoke(["path": path]) == Self.strip.replacingOccurrences(of: "sprite.fill(8)", with: "sprite.fill(9)"))
    }

    @Test("sprite.gif falls back to explicit frame metrics and rejects unsafe requests")
    func spriteGifFallbackAndRejects() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = EditorMobileAgentToolService(projectURL: root)
        _ = await service.handle(
            name: "editor.sprite.generate",
            arguments: ["destination": "Assets/Sprites/rock.png", "source": .string("func build(sprite) { sprite.size(4, 4); sprite.fill(1); }")]
        )
        // No sidecar: a static single-frame GIF.
        let staticGif = await service.handle(name: "editor.sprite.gif", arguments: ["path": "Assets/Sprites/rock.png", "destination": "Assets/Sprites/rock.gif"])
        #expect(staticGif.ok, "\(staticGif.payload)")
        #expect(try Data(contentsOf: root.appendingPathComponent("Assets/Sprites/rock.gif")).starts(with: Data("GIF89a".utf8)))

        #expect(!(await service.handle(name: "editor.sprite.gif", arguments: ["path": "../outside.png", "destination": "Assets/x.gif"])).ok)
        #expect(!(await service.handle(name: "editor.sprite.gif", arguments: ["path": "Assets/Sprites/rock.png", "destination": "../outside.gif"])).ok)
        #expect(!(await service.handle(name: "editor.sprite.gif", arguments: ["path": "Assets/Sprites/rock.png", "destination": "Assets/Sprites/rock.png"])).ok)
        #expect(!(await service.handle(name: "editor.sprite.gif", arguments: ["path": "Assets/Sprites/missing.png", "destination": "Assets/x.gif"])).ok)
    }

    @Test("Bundled palette JSONs match the compiled host presets")
    func paletteJSONsMatchHost() throws {
        let palettesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AdaEditor/Assets/AgentSkills/ada-pixel-art/palettes")
        let names = try FileManager.default.contentsOfDirectory(atPath: palettesURL.path)
            .filter { $0.hasSuffix(".json") }
            .map { $0.replacingOccurrences(of: ".json", with: "") }
            .sorted()
        #expect(names.count >= 10)
        // Resolve each preset through the public VM path so this suite stays
        // compile-safe against hosts without palette presets (red phase).
        for name in names {
            let result = try AdaScriptSpriteGenerator.generate(
                source: """
                func build(sprite) {
                    sprite.size(1, 1);
                    sprite.palettePreset("\(name)");
                    sprite.pixel(0, 0, 1);
                }
                """
            )
            let data = try Data(contentsOf: palettesURL.appendingPathComponent("\(name).json"))
            let document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any], "\(name)")
            let hexes = try #require(document["colors"] as? [String], "\(name)")
            #expect(result.canvas.palette.count > hexes.count, "\(name)")
            for (index, hex) in hexes.enumerated() {
                let color = result.canvas.palette[index + 1]
                #expect(hex == String(format: "#%02X%02X%02X", color.red, color.green, color.blue), "\(name) \(hex)")
            }
        }
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentPixelArtWorkflow-\(UUID())")
        for path in ["Assets/Sprites", "Sources"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Pixel Art Workflow", buildSystem: .adaScript), at: root)
        return root
    }
}
