import AdaAssets
import AdaScene
import Foundation
import Testing

@Suite("Terrain surface residency")
struct TerrainSurfaceCacheTests {
    @Test("Sparse paint and masks have a decoded aggregate budget independent of height pages", arguments: ["paint", "mask", "both"])
    func boundsSurfaceResidency(kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("TerrainSurfaceCache-" + UUID().uuidString, isDirectory: true).standardizedFileURL
        try #require(directory.deletingLastPathComponent() == root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let surface: [TerrainRegionSurfaceSample] = kind == "mask" ? [] : [.init(x: 0, z: 0, tintStrength: 1)]
        let masks: [TerrainRegionRuleMaskSample] = kind == "paint" ? [] : [.init(x: 0, z: 0, maskID: 9, value: 0.25)]
        let bytes = surface.count * MemoryLayout<TerrainRegionSurfaceSample>.stride + masks.count * MemoryLayout<TerrainRegionRuleMaskSample>.stride
        let regions = [Int32(0), 1].map { TerrainRegionAsset(x: $0, z: 0, tiles: [], pages: [], surface: surface, ruleMasks: masks) }
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions(regions, manifest: .init(), at: file.path)
        let cache = try await TerrainRegionCache.open(
            manifestAt: file.path,
            limits: .init(maximumResidentHeightBytes: 0, maximumResidentInstanceBytes: 0, maximumResidentSurfaceBytes: bytes)
        )
        let first = try #require(try await cache.loadRegion(at: .init(x: 0, z: 0)))
        try #require(first.surface == surface && first.ruleMasks == masks)
        await #expect(throws: TerrainRegionCache.CacheError.self) { try await cache.loadRegion(at: .init(x: 1, z: 0)) }
        let statistics = await cache.statistics
        #expect(statistics.residentRegions == 1 && statistics.residentHeightBytes == 0 && statistics.residentInstanceBytes == 0)
        #expect(statistics.inFlightLoads == 0)
        try #require(await cache.evictRegion(at: .init(x: 0, z: 0)))
        let next = try #require(try await cache.loadRegion(at: .init(x: 1, z: 0)))
        #expect(next.surface == surface && next.ruleMasks == masks)
        let disabled = try await TerrainRegionCache.open(manifestAt: file.path, limits: .init(maximumResidentSurfaceBytes: 0))
        await #expect(throws: TerrainRegionCache.CacheError.self) { try await disabled.loadRegion(at: .init(x: 0, z: 0)) }
    }

    @Test("Old residency settings acquire a bounded surface default and preserve explicit settings")
    func legacySurfaceLimits() throws {
        let legacy = Data(#"{"maximumResidentHeightBytes":0,"maximumResidentRegions":1,"maximumConcurrentLoads":1}"#.utf8)
        let limits = try JSONDecoder().decode(TerrainRegionCache.Limits.self, from: legacy)
        #expect(limits.maximumResidentSurfaceBytes == 32 * 1_024 * 1_024)
        let explicit = TerrainRegionCache.Limits(maximumResidentSurfaceBytes: 123)
        #expect(try JSONDecoder().decode(TerrainRegionCache.Limits.self, from: JSONEncoder().encode(explicit)) == explicit)
    }
}
