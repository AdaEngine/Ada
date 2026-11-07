import AdaAssets
@testable import AdaScene
import Foundation
import Math
import Testing

@Suite("Terrain instance cache budgets")
struct TerrainInstanceCacheTests {
    @Test("Cached compact placements use a byte budget independent of zero height pages")
    func boundsInstanceResidency() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("TerrainInstanceCache-" + UUID().uuidString, isDirectory: true).standardizedFileURL
        try #require(directory.deletingLastPathComponent() == root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstRecord = try TerrainRegionInstance(id: 50, prototypeID: 0, localPosition: [1, 0, 1], flags: [])
        let secondRecord = try TerrainRegionInstance(id: 51, prototypeID: 0, localPosition: [1, 0, 1], flags: [])
        let first = TerrainRegionAsset(x: 0, z: 0, tiles: [], pages: [], instances: [firstRecord])
        let second = TerrainRegionAsset(x: 1, z: 0, tiles: [], pages: [], instances: [secondRecord])
        let path = directory.appendingPathComponent("world.aterrain").path
        try await AssetsManager.saveTerrainRegions([first, second], manifest: .init(), at: path)
        let size = MemoryLayout<TerrainRegionInstance>.stride
        let cache = try await TerrainRegionCache.open(
            manifestAt: path,
            limits: .init(maximumResidentHeightBytes: 0, maximumResidentInstanceBytes: size)
        )
        let loaded = try await cache.loadRegion(at: .init(x: 0, z: 0))
        #expect(loaded?.instances == [firstRecord])
        await #expect(throws: TerrainRegionCache.CacheError.self) { try await cache.loadRegion(at: .init(x: 1, z: 0)) }
        let stats = await cache.statistics
        #expect(stats.residentRegions == 1 && stats.residentHeightBytes == 0)
        #expect(stats.residentInstanceBytes == size && stats.inFlightLoads == 0)
        try await cache.pin(.init(x: 0, z: 0), reason: .transaction)
        #expect(await cache.evictRegion(at: .init(x: 0, z: 0)) == false)
        await cache.unpin(.init(x: 0, z: 0), reason: .transaction)
        #expect(await cache.evictRegion(at: .init(x: 0, z: 0)))
        #expect(await cache.statistics.residentInstanceBytes == 0)
        let next = try await cache.loadRegion(at: .init(x: 1, z: 0))
        #expect(next?.instances == [secondRecord])
        #expect(await cache.statistics.residentInstanceBytes == size)
        let fork = try await cache.fork(limits: .init(maximumResidentHeightBytes: 0, maximumResidentInstanceBytes: 0))
        await #expect(throws: TerrainRegionCache.CacheError.self) { try await fork.retain(second) }
        #expect(await fork.statistics.residentRegions == 0)
        #expect(await cache.statistics.residentInstanceBytes == size)
    }

    @Test("Legacy cache limits decode with a bounded placement default and explicit placement budgets round trip")
    func legacyLimitsKeepPlacementBudget() throws {
        let data = Data(#"{"maximumResidentHeightBytes":16384,"maximumResidentRegions":2,"maximumConcurrentLoads":1}"#.utf8)
        let old = try JSONDecoder().decode(TerrainRegionCache.Limits.self, from: data)
        #expect(old.maximumResidentInstanceBytes == 16 * 1_024 * 1_024)
        let explicit = TerrainRegionCache.Limits(maximumResidentInstanceBytes: 64)
        #expect(try JSONDecoder().decode(TerrainRegionCache.Limits.self, from: JSONEncoder().encode(explicit)) == explicit)
    }
}
