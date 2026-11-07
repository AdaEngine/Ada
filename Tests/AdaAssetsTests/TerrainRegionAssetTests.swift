import AdaAssets
import Foundation
import Testing

@Suite("Terrain region resources")
struct TerrainRegionAssetTests {
    @Test("Versioned binary regions round trip through the asset loader without losing signed addresses or sample bits")
    func resourceRoundTrip() async throws {
        let tiles = [TerrainRegionTile(x: 0, z: 3, cellCountX: 2, cellCountZ: 7)]
        var samples = Array(repeating: Float(0), count: 4_096)
        samples[0] = -123.125; samples[63] = .leastNonzeroMagnitude; samples[4_095] = 987.5
        let pages = [TerrainRegionHeightPage(x: 1, z: 3, samples: samples)]
        let source = TerrainRegionAsset(x: -4_096, z: 4_095, tiles: tiles, pages: pages)
        let bytes = try source.encodedData()
        #expect(Array(bytes.prefix(8)) == Array("ADATRN01".utf8))
        #expect(bytes.count == 16_416)  // 24-byte header, one 4-byte tile and one 16,388-byte page.

        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("AdaTerrainRegion-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try #require(directory.deletingLastPathComponent() == root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("region.atregion")
        try bytes.write(to: file)
        let loaded = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: file.path)
        #expect(loaded.x == source.x && loaded.z == source.z)
        #expect(loaded.tiles == tiles)
        #expect(loaded.pages == pages)
        #expect(loaded.pages[0].samples.map(\.bitPattern) == samples.map(\.bitPattern))
        #expect(try loaded.encodedData() == bytes)
    }

    @Test("Malformed regions reject counts, coordinates, duplicate pages, nonfinite samples and trailing bytes")
    func rejectsMalformedData() throws {
        let valid = TerrainRegionAsset(
            x: 0,
            z: 0,
            tiles: [.init(x: 0, z: 0)],
            pages: [.init(x: 0, z: 0, samples: Array(repeating: 1, count: 4_096))]
        )
        let bytes = try valid.encodedData()
        func rejects(_ data: Data) { #expect(throws: (any Error).self) { try TerrainRegionAsset(data: data) } }
        rejects(Data(bytes.prefix(7)))
        rejects(bytes + Data([0]))
        var changed = bytes
        changed[7] = 50  // Unsupported format version.
        rejects(changed)
        changed = bytes
        changed.replaceSubrange(16..<20, with: [255, 255, 255, 255])  // Tile count must be bounded before allocation.
        rejects(changed)
        changed = bytes
        changed.replaceSubrange(8..<12, with: [255, 255, 255, 127])  // Address outside supported grid.
        rejects(changed)
        changed = bytes
        changed[24] = 4  // Local tile address outside 0...3.
        rejects(changed)
        changed = bytes
        changed[30] = 1  // Reserved page byte must remain zero.
        rejects(changed)
        changed = bytes
        changed.replaceSubrange(32..<36, with: [0, 0, 128, 127])  // Positive infinity height.
        rejects(changed)
        changed = bytes
        changed.replaceSubrange(20..<24, with: [2, 0, 0, 0])
        changed.append(bytes.subdata(in: 28..<bytes.count))  // Duplicate canonical page.
        rejects(changed)
        let tooMany = TerrainRegionAsset(x: 0, z: 0, tiles: Array(repeating: .init(x: 0, z: 0), count: 17), pages: [])
        #expect(throws: (any Error).self) { try tooMany.encodedData() }
    }
}
