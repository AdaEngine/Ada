@testable @_spi(AdaEngine) @_spi(Internal) import AdaAssets
import AdaScene
import Foundation
import Testing

@Suite("Terrain region residency")
struct TerrainRegionCacheTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("AdaTerrainResidency-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try #require(directory.deletingLastPathComponent() == root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func region(x: Int32 = 0, pageCount: Int = 1) -> TerrainRegionAsset {
        var pages: [TerrainRegionHeightPage] = []
        for index in 0..<pageCount {
            pages.append(.init(x: UInt8(index % 4), z: UInt8(index / 4), samples: Array(repeating: Float(3), count: 4_096)))
        }
        return .init(x: x, z: 0, tiles: [.init(x: 0, z: 0)], pages: pages)
    }

    @Test("Resident data survives later file corruption until explicitly evicted, while absent regions stay empty")
    func retainsLoadedGeneration() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("world.aterrain")
        let manifest = try await AssetsManager.saveTerrainRegions([region()], manifest: .init(), at: file.path)
        let ref = try #require(manifest.heightRegions.first)
        let cache = try await TerrainRegionCache.open(manifestAt: file.path)
        let first = try await cache.loadRegion(at: .init(x: 0, z: 0))
        #expect(first?.pages[0].samples[0] == 3)
        let stats = await cache.statistics
        #expect(stats.residentRegions == 1)
        #expect(stats.residentHeightBytes == 16_384)
        try Data("bad".utf8).write(to: directory.appendingPathComponent(ref.fileName))
        let retained = try await cache.loadRegion(at: .init(x: 0, z: 0))
        #expect(retained?.pages[0].samples[0] == 3)
        let missing = try await cache.loadRegion(at: .init(x: -1, z: 0))
        #expect(missing == nil)
        #expect(await cache.evictRegion(at: .init(x: 0, z: 0)))
        await #expect(throws: TerrainRegionError.self) { try await cache.loadRegion(at: .init(x: 0, z: 0)) }
    }

    @Test("Aggregate resident height limits reject another payload without dropping already resident data")
    func boundsResidentPages() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions([region(), region(x: 1, pageCount: 2)], manifest: .init(), at: file.path)
        let cache = try await TerrainRegionCache.open(manifestAt: file.path, limits: .init(maximumResidentHeightBytes: 16_384))
        _ = try await cache.loadRegion(at: .init(x: 0, z: 0))
        await #expect(throws: TerrainRegionCache.CacheError.self) { try await cache.loadRegion(at: .init(x: 1, z: 0)) }
        let stats = await cache.statistics
        #expect(stats.residentRegions == 1 && stats.residentHeightBytes == 16_384)
        #expect(stats.inFlightLoads == 0)
    }

    @Test("Dirty and selected pins independently prevent eviction; count limits recover after releasing a region")
    func pinsAndCountLimits() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions([region(), region(x: 1)], manifest: .init(), at: file.path)
        let cache = try await TerrainRegionCache.open(manifestAt: file.path, limits: .init(maximumResidentRegions: 1))
        let first = TerrainRegionCoordinate(x: 0, z: 0)
        _ = try await cache.loadRegion(at: first)
        try await cache.pin(first, reason: .dirty)
        try await cache.pin(first, reason: .selected)
        #expect(await cache.evictRegion(at: first) == false)
        await cache.unpin(first, reason: .dirty)
        #expect(await cache.evictRegion(at: first) == false)
        await #expect(throws: TerrainRegionCache.CacheError.self) { try await cache.loadRegion(at: .init(x: 1, z: 0)) }
        await cache.unpin(first, reason: .selected)
        #expect(await cache.evictRegion(at: first))
        let next = try await cache.loadRegion(at: .init(x: 1, z: 0))
        #expect(next?.x == 1)
    }

    @Test("A cache keeps its originating asset scope when another world requests a region")
    func preservesOriginatingScope() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstRoot = directory.appendingPathComponent("First", isDirectory: true)
        let secondRoot = directory.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let layout = TerrainManifestAsset(heightRegions: [.init(x: 0, z: 0, fileName: "height.atregion")])
        try layout.encodedData().write(to: firstRoot.appendingPathComponent("world.aterrain"))
        try layout.encodedData().write(to: secondRoot.appendingPathComponent("world.aterrain"))
        let original = region()
        let other = TerrainRegionAsset(
            x: 0,
            z: 0,
            tiles: original.tiles,
            pages: [.init(x: 0, z: 0, samples: Array(repeating: Float(9), count: 4_096))]
        )
        try original.encodedData().write(to: firstRoot.appendingPathComponent("height.atregion"))
        try other.encodedData().write(to: secondRoot.appendingPathComponent("height.atregion"))
        let firstScope = UUID(), secondScope = UUID()
        try AssetsManager.initialize(filePath: #filePath, assetBundleResourceURL: firstRoot, scopeID: firstScope)
        try AssetsManager.initialize(filePath: #filePath, assetBundleResourceURL: secondRoot, scopeID: secondScope)
        let cache = try await AssetsManager.withScope(firstScope) { try await TerrainRegionCache.open(manifestAt: "@res://world.aterrain") }
        let loaded = try await AssetsManager.withScope(secondScope) { try await cache.loadRegion(at: .init(x: 0, z: 0)) }
        #expect(loaded?.pages[0].samples[0] == 3)
        await AssetsManager.destroyScope(firstScope)
        await AssetsManager.destroyScope(secondScope)
    }
}
