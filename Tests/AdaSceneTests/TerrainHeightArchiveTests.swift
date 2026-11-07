import AdaAssets
import AdaScene
import Foundation
import Math
import Testing

@Suite("Terrain height resource bridge")
struct TerrainHeightArchiveTests {
    @Test("Legacy partial tiles retain shape and normals after actual region-file loading")
    func legacyResourceRoundTrip() async throws {
        var terrain = Terrain3D(resolution: 5, size: 8)
        for z in 0..<5 { for x in 0..<5 { terrain.heights[z * 5 + x] = Float(x * x - z) / 8 } }
        let source = try TerrainHeightStorage(importing: terrain)
        let archive = try #require(try source.regionAsset(at: .init(x: 0, z: 0)))
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("AdaTerrainArchive-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try #require(directory.deletingLastPathComponent() == root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("region.atregion")
        try archive.encodedData().write(to: file)
        let loaded = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: file.path)
        let restored = try TerrainHeightStorage(regions: [loaded], spacing: source.spacing, origin: source.origin)
        #expect(restored.resourceCoordinates == source.resourceCoordinates)
        #expect(restored.tileCoordinates == source.tileCoordinates)
        let before = try #require(source.snapshot(of: .init(x: 0, z: 0)))
        let after = try #require(restored.snapshot(of: .init(x: 0, z: 0)))
        #expect(after.heights == before.heights)
        #expect(after.normals == before.normals)
        #expect(after.meshDescriptor().positions.elements == before.meshDescriptor().positions.elements)
        #expect(after.meshDescriptor().indicies == before.meshDescriptor().indicies)
        #expect(after.cellCountX == 4 && after.cellCountZ == 4)
        #expect(restored.height(at: .init(1.25, -0.75)) == source.height(at: .init(1.25, -0.75)))
    }

    @Test("Boundary-only pages survive independently and restores enforce aggregate page budgets")
    func canonicalBoundaryAndBudget() throws {
        let source = try TerrainHeightStorage(memoryBudgetBytes: 16_384)
        try source.allocateRegion(at: .init(x: 4_095, z: -1))
        try source.setHeight(6, at: .init(x: 1_048_576, z: -1))
        let expected = [TerrainRegionCoordinate(x: 4_095, z: -1), .init(x: 4_096, z: -1)]
        #expect(source.resourceCoordinates == expected)
        let physical = try #require(try source.regionAsset(at: expected[0]))
        let boundary = try #require(try source.regionAsset(at: expected[1]))
        #expect(physical.tiles.count == 16 && physical.pages.isEmpty)
        #expect(boundary.tiles.isEmpty && boundary.pages.count == 1)
        let restored = try TerrainHeightStorage(regions: [boundary, physical], memoryBudgetBytes: 16_384)
        #expect(restored.height(atSample: .init(x: 1_048_576, z: -1)) == 6)
        #expect(restored.residentHeightBytes == 16_384)
        #expect(restored.resourceCoordinates == expected)
        #expect(throws: (any Error).self) { try TerrainHeightStorage(regions: [boundary, physical], memoryBudgetBytes: 0) }
        #expect(throws: (any Error).self) { try TerrainHeightStorage(regions: [physical, physical]) }
        #expect(try source.regionAsset(at: .init(x: 0, z: 0)) == nil)
        #expect(throws: (any Error).self) { try source.regionAsset(at: .init(x: .max, z: 0)) }
    }
}
