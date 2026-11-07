import AdaAssets
import Foundation
import Testing

@Suite("Terrain mesh palette persistence")
struct TerrainMeshPaletteTests {
    private func bytes(_ entries: [[String: Any]], version: Int = 2) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": version, "spacing": 1, "originX": 0, "originZ": 0, "heightRegions": [], "meshPrototypes": entries])
    }

    @Test("Stable prototype references survive loading and both atomic save modes")
    func paletteSurvivesRegionSaves() async throws {
        let entries: [[String: Any]] = [["id": 17, "assetPath": "Models/rock.glb", "scene": 1, "maximumDistance": 500]]
        let decoded = try? TerrainManifestAsset(data: bytes(entries))
        let manifest = try #require(decoded != nil ? decoded : nil)
        func check(_ value: TerrainManifestAsset) throws {
            let json = try #require(JSONSerialization.jsonObject(with: value.encodedData()) as? [String: Any])
            #expect(json["version"] as? Int == 2)
            let table = try #require(json["meshPrototypes"] as? [[String: Any]])
            #expect(table.count == 1)
            #expect(table.first?["id"] as? Int == 17)
            #expect(table.first?["assetPath"] as? String == "Models/rock.glb")
            #expect(table.first?["scene"] as? Int == 1)
            #expect(table.first?["maximumDistance"] as? Int == 500)
        }
        try check(manifest)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("TerrainPalette-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try #require(directory.deletingLastPathComponent() == root)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("world.aterrain")
        let region = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0)], pages: [])
        let saved = try await AssetsManager.saveTerrainRegions([region], manifest: manifest, at: file.path)
        try check(saved)
        let updated = try await AssetsManager.saveTerrainRegions([], manifest: saved, at: file.path, mode: .update(removing: []))
        try check(updated)
        try check(try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path))
        let legacy = try TerrainManifestAsset(data: bytes([], version: 1))
        let json = try #require(JSONSerialization.jsonObject(with: legacy.encodedData()) as? [String: Any])
        #expect(json["version"] as? Int == 1)
    }

    @Test("Mesh palettes bound count and reject ambiguous IDs, traversal, invalid scenes and distances")
    func rejectsInvalidPalette() throws {
        let valid: [String: Any] = ["id": 7, "assetPath": "Models/rock.glb"]
        let invalidPaths = [
            "../rock.glb", "/rock.glb", "C:/rock.glb", "@res://rock.glb", "Models\\rock.glb", "Models/%2e%2e/rock.glb", "Models//rock.glb", "Models/./rock.glb", "rock.exe",
            "rock.glb?secret=1", "rock\u{0}.glb",
        ]
        for path in invalidPaths {
            #expect(throws: (any Error).self) { try TerrainManifestAsset(data: bytes([["id": 7, "assetPath": path]])) }
        }
        #expect(throws: (any Error).self) { try TerrainManifestAsset(data: bytes([valid, valid])) }
        #expect(throws: (any Error).self) { try TerrainManifestAsset(data: bytes(Array(repeating: valid, count: 257))) }
        for extra: [String: Any] in [["scene": -1], ["scene": 4096], ["maximumDistance": 0], ["maximumDistance": -1], ["id": 65536]] {
            let value = valid.merging(extra) { _, new in new }
            #expect(throws: (any Error).self) { try TerrainManifestAsset(data: bytes([value])) }
        }
        #expect(throws: (any Error).self) { try TerrainManifestAsset(data: bytes([valid], version: 1)) }
    }
}
