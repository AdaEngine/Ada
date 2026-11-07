import AdaAssets
import Foundation
import Math
import Testing

@Suite("Terrain instance region resources")
struct TerrainRegionInstanceTests {
    @Test("Compact placement regions preserve stable records, attachment and legacy height data through real asset loading")
    func compactPlacementRoundTrip() async throws {
        let first = try TerrainRegionInstance(
            id: 0xfedc_ba98_7654_3210,
            prototypeID: 65_000,
            localPosition: [3.5, 12.25, 4.75],
            rotation: Quat(axis: [0, 1, 0], angle: 1.2),
            scale: [-2, 3, 4],
            tint: [0.25, 0.5, 0.75, 1],
            seed: 0xffee_ddcc,
            flags: [.anchored, .alignToNormal],
            anchorNormal: [0, -1, 0],
            anchorOffset: 0.25
        )
        let second = try TerrainRegionInstance(id: 0, prototypeID: 1, localPosition: [255.75, -2, 255.5], flags: [.collision])
        let source = TerrainRegionAsset(x: -1, z: 2, tiles: [.init(x: 0, z: 0)], pages: [], instances: [first, second])
        let data = try source.encodedData()
        #expect(data.prefix(8) == Data("ADATRN02".utf8))
        #expect(data.count == 196)  // Header24 +2section headers32 +height layout12 +2compact records128.
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("TerrainInstances-" + UUID().uuidString, isDirectory: true).standardizedFileURL
        try #require(directory.deletingLastPathComponent() == root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("placements.atregion")
        try data.write(to: url)
        let loaded = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: url.path)
        #expect(loaded.x == -1 && loaded.z == 2)
        #expect(loaded.tiles == source.tiles)
        #expect(loaded.instances == source.instances)
        #expect(try loaded.encodedData() == data)
        let record = try #require(loaded.instances.first)
        #expect(record.id == first.id && record.seed == first.seed && record.prototypeID == 65_000)
        #expect(record.localPosition == first.localPosition && record.scale == first.scale)
        #expect(record.anchorNormal.y < -0.9999)
        #expect(abs(record.tint.x - 0.25) <= 1 / 255)
        #expect(record.anchorOffset == 0.25 && record.flags == [.anchored, .alignToNormal])
        let legacy = TerrainRegionAsset(x: -1, z: 2, tiles: source.tiles, pages: [])
        let oldBytes = try legacy.encodedData()
        #expect(oldBytes.prefix(8) == Data("ADATRN01".utf8))
        #expect(try TerrainRegionAsset(data: oldBytes).instances.isEmpty)
    }

    @Test("Placement values and region identities are validated before encoding")
    func rejectsInvalidPlacements() throws {
        #expect(throws: (any Error).self) { try TerrainRegionInstance(id: 1, prototypeID: 0, localPosition: [-0.1, 0, 0]) }
        #expect(throws: (any Error).self) { try TerrainRegionInstance(id: 1, prototypeID: 0, localPosition: [256, 0, 0]) }
        #expect(throws: (any Error).self) { try TerrainRegionInstance(id: 1, prototypeID: 0, localPosition: [0, .infinity, 0]) }
        #expect(throws: (any Error).self) { try TerrainRegionInstance(id: 1, prototypeID: 0, localPosition: .zero, rotation: Quat()) }
        #expect(throws: (any Error).self) { try TerrainRegionInstance(id: 1, prototypeID: 0, localPosition: .zero, scale: [0, 1, 1]) }
        #expect(throws: (any Error).self) { try TerrainRegionInstance(id: 1, prototypeID: 0, localPosition: .zero, tint: [1, 1, .nan, 1]) }
        #expect(throws: (any Error).self) { try TerrainRegionInstance(id: 1, prototypeID: 0, localPosition: .zero, flags: .init(rawValue: 8)) }
        #expect(throws: (any Error).self) { try TerrainRegionInstance(id: 1, prototypeID: 0, localPosition: .zero, anchorNormal: .zero) }
        let record = try TerrainRegionInstance(id: 5, prototypeID: 0, localPosition: .zero)
        let duplicate = TerrainRegionAsset(x: 0, z: 0, tiles: [], pages: [], instances: [record, record])
        #expect(throws: (any Error).self) { try duplicate.encodedData() }
        let excessive = TerrainRegionAsset(x: 0, z: 0, tiles: [], pages: [], instances: Array(repeating: record, count: 65_537))
        #expect(throws: (any Error).self) { try excessive.encodedData() }
    }

    @Test("Section and compact-record corruption reject before expanding placement arrays")
    func rejectsMalformedPlacementSections() throws {
        let record = try TerrainRegionInstance(id: 1, prototypeID: 0, localPosition: .zero, flags: [])
        let source = TerrainRegionAsset(x: 0, z: 0, tiles: [], pages: [], instances: [record])
        let bytes = try source.encodedData()
        try #require(bytes.count == 104)  // One section header, one64-byte record.
        func rejects(_ data: Data) { #expect(throws: (any Error).self) { try TerrainRegionAsset(data: data) } }
        rejects(Data(bytes.prefix(32)))
        rejects(bytes + Data([0]))
        var changed = bytes
        changed.replaceSubrange(16..<20, with: [255, 255, 255, 255])
        rejects(changed)
        changed = bytes
        changed.replaceSubrange(28..<32, with: [1, 0, 1, 0])  // Record count65537, length64.
        rejects(changed)
        changed = bytes
        changed.replaceSubrange(64..<72, with: repeatElement(UInt8(0), count: 8))  // Zero quaternion.
        rejects(changed)
        changed = bytes
        changed[103] = 1  // Reserved record word.
        rejects(changed)
        changed = bytes
        changed[24] = 99  // Unknown required section.
        rejects(changed)
    }
}
