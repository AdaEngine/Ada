import AdaAssets
import Foundation
import Testing

@Suite("Terrain material resources")
struct TerrainMaterialManifestTests {
    private func document(layers: [[String: Any]], rules: [[String: Any]] = [], fallback: Int = 7) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": 3, "spacing": 1, "originX": 0, "originZ": 0, "heightRegions": [],
            "materials": ["layers": layers, "fallbackLayerID": fallback, "interiorLayerID": fallback, "rules": rules],
        ])
    }

    private func layer(_ id: Int) -> [String: Any] {
        ["id": id, "name": "Surface \(id)", "albedoPath": "Textures/grass.png", "scale": 2, "projection": "planar"]
    }

    @Test("Version-three terrain manifests retain 32 stable material IDs, map references and automatic rules")
    func terrainMaterialManifestRoundTrip() throws {
        let layers = (7..<39).reversed().map(layer)
        let rule: [String: Any] = [
            "layerID": 7, "enabled": true, "weight": 1, "height": ["minimum": -10, "maximum": 50, "transition": 3],
            "slope": ["minimum": 0, "maximum": 45, "transition": 5], "seed": 42,
        ]
        let data = try document(layers: layers, rules: [rule])
        #expect(throws: Never.self) {
            let asset = try TerrainManifestAsset(data: data)
            let saved = try #require(JSONSerialization.jsonObject(with: asset.encodedData()) as? [String: Any])
            #expect(saved["version"] as? Int == 3)
            let materials = try #require(saved["materials"] as? [String: Any])
            let encodedLayers = try #require(materials["layers"] as? [[String: Any]])
            #expect(encodedLayers.compactMap { $0["id"] as? Int } == Array((7..<39).reversed()))
            #expect(encodedLayers.first?["albedoPath"] as? String == "Textures/grass.png")
            let encodedRules = try #require(materials["rules"] as? [[String: Any]])
            #expect(encodedRules.first?["layerID"] as? Int == 7)
            #expect(materials["fallbackLayerID"] as? Int == 7)
            #expect(try TerrainManifestAsset(data: asset.encodedData()).encodedData() == asset.encodedData())
        }
    }

    @Test("Material palettes reject excessive counts, duplicate IDs, invalid map paths, scales and dangling targets")
    func terrainMaterialManifestRejectsInvalidResources() throws {
        var path = layer(7)
        path["normalPath"] = "../outside.png"
        var scale = layer(7)
        scale["scale"] = 0
        var projection = layer(7)
        projection["projection"] = "unknown"
        let documents = [
            try document(layers: (7..<40).map(layer)),
            try document(layers: [layer(7), layer(7)]),
            try document(layers: [path]), try document(layers: [scale]), try document(layers: [projection]),
            try document(layers: [layer(7)], fallback: 8),
            try document(layers: [layer(7)], rules: [["layerID": 8, "weight": 1]]),
            try document(layers: [layer(7)], rules: Array(repeating: ["layerID": 7, "weight": 1], count: 129)),
        ]
        for data in documents {
            #expect(throws: (any Error).self) { _ = try TerrainManifestAsset(data: data) }
        }
    }

    @Test("Material palettes survive complete and incremental atomic region saves")
    func terrainMaterialManifestSurvivesRegionSaves() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("TerrainMaterials-" + UUID().uuidString, isDirectory: true).standardizedFileURL
        try #require(directory.deletingLastPathComponent() == root)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: Never.self) {
            let input = try TerrainManifestAsset(data: document(layers: [layer(7)]))
            let path = directory.appendingPathComponent("world.aterrain").path
            let region = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0)], pages: [])
            let first = try await AssetsManager.saveTerrainRegions([region], manifest: input, at: path)
            let second = try await AssetsManager.saveTerrainRegions([], manifest: first, at: path, mode: .update(removing: []))
            let loaded = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: path)
            for manifest in [first, second, loaded] {
                let saved = try #require(JSONSerialization.jsonObject(with: manifest.encodedData()) as? [String: Any])
                let materials = try #require(saved["materials"] as? [String: Any])
                let layers = try #require(materials["layers"] as? [[String: Any]])
                #expect(layers.first?["id"] as? Int == 7)
                #expect(layers.first?["albedoPath"] as? String == "Textures/grass.png")
            }
        }
    }

    @Test("Saved texture variation preserves full seeds and controls through both native save modes")
    func terrainMaterialVariationRoundTrip() async throws {
        var inputLayer = layer(7)
        inputLayer["variation"] = [
            "isEnabled": true, "seed": UInt64.max, "flipU": true, "flipV": false,
            "quarterTurns": true, "randomOffset": true, "cellScale": 2, "macroStrength": 0.15, "macroScale": 32,
        ] as [String: Any]
        let input = try TerrainManifestAsset(data: document(layers: [inputLayer]))
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("TerrainVariation-" + UUID().uuidString, isDirectory: true).standardizedFileURL
        try #require(directory.deletingLastPathComponent() == root)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("world.aterrain").path
        let region = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0)], pages: [])
        let first = try await AssetsManager.saveTerrainRegions([region], manifest: input, at: path)
        let second = try await AssetsManager.saveTerrainRegions([], manifest: first, at: path, mode: .update(removing: []))
        let loaded = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: path)
        for manifest in [input, first, second, loaded] {
            let saved = try #require(JSONSerialization.jsonObject(with: manifest.encodedData()) as? [String: Any])
            let palette = try #require(saved["materials"] as? [String: Any])
            let layers = try #require(palette["layers"] as? [[String: Any]])
            let variation = layers.first?["variation"] as? [String: Any]
            #expect((variation?["seed"] as? UInt64) == UInt64.max)
            #expect(variation?["isEnabled"] as? Bool == true && variation?["flipV"] as? Bool == false)
            #expect(variation?["cellScale"] as? Int == 2 && variation?["macroScale"] as? Int == 32)
        }
    }

    @Test("Texture variation rejects invalid cell and macro ranges before preparing resources")
    func terrainMaterialVariationRejectsInvalidRanges() throws {
        for (key, value) in [("cellScale", 0.0), ("macroStrength", -1.0), ("macroStrength", 1.1), ("macroScale", 0.0)] {
            var inputLayer = layer(7)
            inputLayer["variation"] = ["isEnabled": true, key: value]
            let data = try document(layers: [inputLayer])
            #expect(throws: (any Error).self) { _ = try TerrainManifestAsset(data: data) }
        }
    }
}
