import AdaAssets
import AdaScene
import Foundation
import Testing

@Suite("Terrain surface palette admission")
struct TerrainSurfacePaletteAdmissionTests {
    @Test("All active saved paint IDs are checked on region admission, including data-only regions", arguments: ["missing", "absent", "valid"])
    func surfacePaletteAdmission(kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("TerrainPaintPalette-" + UUID().uuidString, isDirectory: true).standardizedFileURL
        try #require(directory.deletingLastPathComponent() == root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = TerrainRegionAsset(x: 0, z: 0, tiles: [], pages: [], surface: [.init(x: 32, z: 32, tintStrength: 1)])
        let paint = TerrainRegionSurfaceSample(x: 32, z: 32, layerIDs: [35, 0, 0, 0], weights: [1, 0, 0, 0], overrideStrength: 1)
        let painted = TerrainRegionAsset(x: 1, z: 0, tiles: [], pages: [], surface: [paint])
        let id: UInt16 = kind == "valid" ? 35 : 7
        let palette = TerrainMaterialPalette(layers: [.init(id: id, name: "Registered layer")], fallbackLayerID: id)
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions([good, painted], manifest: .init(materials: kind == "absent" ? nil : palette), at: file.path)
        let cache = try await TerrainRegionCache.open(manifestAt: file.path)
        let retained = try #require(try await cache.loadRegion(at: .init(x: 0, z: 0)))
        try #require(retained.surface == good.surface)
        if kind == "valid" {
            let accepted = try #require(try await cache.loadRegion(at: .init(x: 1, z: 0)))
            #expect(accepted.surface == [paint])
        } else {
            await #expect(throws: TerrainRegionCache.CacheError.self) { try await cache.loadRegion(at: .init(x: 1, z: 0)) }
        }
        let statistics = await cache.statistics
        #expect(statistics.residentRegions == (kind == "valid" ? 2 : 1))
        let first = try #require(try await cache.loadRegion(at: .init(x: 0, z: 0)))
        #expect(first.surface == good.surface && statistics.inFlightLoads == 0)
    }
}
