@testable @_spi(AdaEngine) @_spi(Internal) import AdaAssets
import AdaScene
import Foundation
import Testing

@Suite("Lazy scoped terrain volume resources")
struct TerrainVolumeResourceTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let folder = root.appendingPathComponent("TerrainVolumeResource-" + UUID().uuidString).standardizedFileURL
        try #require(folder.deletingLastPathComponent() == root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ folder: URL, value: Float = -1, tag: UInt32 = 7, x: Int32 = -1) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let refs = [
            TerrainVolumeBrickReference(x: -1, y: 2, z: -3, fileName: "selected.atvolbrick"),
            TerrainVolumeBrickReference(x: 1, y: 0, z: 0, fileName: "unavailable.atvolbrick")
        ]
        let doc = TerrainVolumeDocumentAsset(cellSize: 0.5, operations: [], bricks: refs)
        try doc.encodedData().write(to: folder.appendingPathComponent("solid.atvolume"))
        let asset = TerrainVolumeBrickAsset(
            x: x,
            y: 2,
            z: -3,
            values: Array(repeating: value, count: TerrainVolumeBrickAsset.sampleCount),
            materialTags: Array(repeating: tag, count: TerrainVolumeBrickAsset.sampleCount)
        )
        try asset.encodedData().write(to: folder.appendingPathComponent("selected.atvolbrick"))
        let manifest = TerrainManifestAsset(materials: .init(layers: [.init(id: 7, name: "Rock")], fallbackLayerID: 7), volumeFileName: "solid.atvolume")
        try manifest.encodedData().write(to: folder.appendingPathComponent("world.aterrain"))
    }

    @Test("Metadata and requested bricks retain their originating project without reading unavailable neighbors")
    func originatingScope() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("First"), second = folder.appendingPathComponent("Second")
        try write(first, value: -3); try write(second, value: -9)
        let scope = UUID(), other = UUID()
        try AssetsManager.initialize(filePath: #filePath, assetBundleResourceURL: first, scopeID: scope)
        try AssetsManager.initialize(filePath: #filePath, assetBundleResourceURL: second, scopeID: other)
        let cache = try await AssetsManager.withScope(scope) { try await TerrainRegionCache.open(manifestAt: "@res://world.aterrain") }
        let resources = try #require(try await AssetsManager.withScope(other) { try await cache.loadVolumeResources() })
        #expect(resources.document.cellSize == 0.5 && resources.document.bricks.count == 2)
        let bricks = try await AssetsManager.withScope(other) { try await resources.loadBricks(at: [.init(x: -1, y: 2, z: -3)]) }
        #expect(bricks.count == 1 && bricks.first?.values.first == -3)
        #expect(bricks.first?.materialTags.first == 7)
        let empty = try await resources.loadBricks(at: [])
        #expect(empty.isEmpty)
        await AssetsManager.destroyScope(scope); await AssetsManager.destroyScope(other)
    }

    @Test("Requested memory/count, duplicate and undeclared addresses are rejected before payload reads")
    func preflight() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(folder)
        let cache = try await TerrainRegionCache.open(manifestAt: folder.appendingPathComponent("world.aterrain").path)
        let resources = try #require(try await cache.loadVolumeResources())
        let coordinate = TerrainVolumeBrickCoordinate(x: -1, y: 2, z: -3)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("selected.atvolbrick"))
        await #expect(throws: TerrainVolumeFieldError.memoryBudgetExceeded) { try await resources.loadBricks(at: [coordinate], maximumBytes: 0) }
        await #expect(throws: TerrainVolumeFieldError.memoryBudgetExceeded) { try await resources.loadBricks(at: [coordinate], maximumBricks: 0) }
        await #expect(throws: TerrainVolumeFieldError.invalidCoordinate) { try await resources.loadBricks(at: [coordinate, coordinate]) }
        await #expect(throws: TerrainVolumeFieldError.invalidCoordinate) { try await resources.loadBricks(at: [.init(x: 0, y: 0, z: 0)]) }
    }

    @Test("Cached coordinates and material tags must match declared resources", arguments: [false, true])
    func rejectsMismatchedPayload(material: Bool) async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(folder, tag: material ? 8 : 7, x: material ? -1 : 0)
        let cache = try await TerrainRegionCache.open(manifestAt: folder.appendingPathComponent("world.aterrain").path)
        let resources = try #require(try await cache.loadVolumeResources())
        await #expect(throws: (any Error).self) { try await resources.loadBricks(at: [.init(x: -1, y: 2, z: -3)]) }
    }
}
