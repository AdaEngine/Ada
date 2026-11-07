import AdaAssets
import Foundation
import Testing

@Suite("Terrain manifest resources")
struct TerrainManifestAssetTests {
    @Test("A versioned portable manifest round trips through actual asset loading")
    func manifestResourceRoundTrip() async throws {
        let refs = [TerrainRegionReference(x: -4, z: 7, fileName: "height-minus4-7.atregion")]
        let source = TerrainManifestAsset(spacing: 2, originX: -8, originZ: 12, heightRegions: refs)
        let bytes = try source.encodedData()
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("AdaTerrainManifest-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try #require(directory.deletingLastPathComponent() == root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("world.aterrain")
        try bytes.write(to: file)
        let loaded = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        #expect(loaded.spacing == 2 && loaded.originX == -8 && loaded.originZ == 12)
        #expect(loaded.heightRegions == refs)
        #expect(try loaded.encodedData() == bytes)
    }

    @Test("References cannot traverse, encode path separators or alias multiple region resources")
    func rejectsInvalidReferences() throws {
        let invalid = [
            "../a.atregion", "/tmp/a.atregion", "@res://a.atregion", "a%2fb.atregion", "C:\\a.atregion",
            "a.atregion/evil", "a\0.atregion", ".atregion", "é.atregion", "*.atregion",
            String(repeating: "a", count: 129) + ".atregion",
        ]
        for file in invalid {
            let asset = TerrainManifestAsset(heightRegions: [.init(x: 0, z: 0, fileName: file)])
            #expect(throws: (any Error).self) { try asset.encodedData() }
        }
        let duplicateAddress = TerrainManifestAsset(heightRegions: [
            .init(x: 0, z: 0, fileName: "a.atregion"),
            .init(x: 0, z: 0, fileName: "b.atregion"),
        ])
        #expect(throws: (any Error).self) { try duplicateAddress.encodedData() }
        let duplicateFile = TerrainManifestAsset(heightRegions: [
            .init(x: 0, z: 0, fileName: "a.atregion"),
            .init(x: 1, z: 0, fileName: "a.atregion"),
        ])
        #expect(throws: (any Error).self) { try duplicateFile.encodedData() }
        let invalidAddress = TerrainManifestAsset(heightRegions: [.init(x: .max, z: 0, fileName: "a.atregion")])
        #expect(throws: (any Error).self) { try invalidAddress.encodedData() }
    }

    @Test("Unknown versions, invalid spacing and oversized region tables fail instead of loading empty terrain")
    func rejectsInvalidManifest() throws {
        let future = Data(#"{"version":5,"spacing":1,"originX":0,"originZ":0,"heightRegions":[]}"#.utf8)
        #expect(throws: (any Error).self) { try TerrainManifestAsset(data: future) }
        for spacing: Float in [0, -1, .infinity, .nan, .greatestFiniteMagnitude] {
            #expect(throws: (any Error).self) { try TerrainManifestAsset(spacing: spacing).encodedData() }
        }
        var many: [TerrainRegionReference] = []
        for index in 0..<16_385 {
            let x = Int32(index % 128) - 64
            let z = Int32(index / 128) - 64
            many.append(.init(x: x, z: z, fileName: "region-\(index).atregion"))
        }
        #expect(throws: (any Error).self) { try TerrainManifestAsset(heightRegions: many).encodedData() }
        let traversal = Data(#"{"version":1,"spacing":1,"originX":0,"originZ":0,"heightRegions":[{"x":0,"z":0,"fileName":"../escape.atregion"}]}"#.utf8)
        #expect(throws: (any Error).self) { try TerrainManifestAsset(data: traversal) }
    }
}
