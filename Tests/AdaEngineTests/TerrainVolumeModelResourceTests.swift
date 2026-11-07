@testable @_spi(AdaEngine) @_spi(Internal) import AdaAssets
import AdaEngine
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Portable solid model operands load from the originating project and enforce inherited importer limits")
    func volumeOperandLoadsScopedModel() async throws {
        _ = try await makeApp()
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("First"), second = folder.appendingPathComponent("Second")
        let operation = TerrainVolumeOperation(operation: .union, operand: .mesh(assetPath: "solid.obj", scene: nil), transform: .init(translation: [0, 3, 0]))
        try writeVolumeOBJ(first, offset: 0, operation: operation)
        try writeVolumeOBJ(second, offset: 20, operation: operation)
        let scope = UUID(), other = UUID()
        try AssetsManager.initialize(filePath: #filePath, assetBundleResourceURL: first, scopeID: scope)
        try AssetsManager.initialize(filePath: #filePath, assetBundleResourceURL: second, scopeID: other)
        let cache = try await AssetsManager.withScope(scope) { @Sendable in try await TerrainRegionCache.open(manifestAt: "@res://world.aterrain") }
        let resources = try #require(try await cache.loadVolumeResources())
        let prepared = try? await AssetsManager.withScope(other) { @Sendable in try await resources.loadPreparedMesh(operationID: operation.id) }
        let mesh = try #require(prepared, "A portable closed OBJ operand must prepare in the cache's original scope")
        let base = try TerrainHeightStorage(importing: Terrain3D(resolution: 65, size: 64))
        let field = try TerrainVolumeField(document: resources.document, base: base, preparedMeshes: [mesh])
        #expect(try field.sample(at: [0, 3, 0]).value < 0)
        #expect(try field.sample(at: [20, 3, 0]).value > 0)
        await #expect(throws: TerrainVolumeFieldError.memoryBudgetExceeded) { try await resources.loadPreparedMesh(operationID: operation.id, maximumBytes: 0) }
        let limited = try await AssetsManager.withScope(scope) { @Sendable in
            try await ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 16)) {
                try await TerrainRegionCache.open(manifestAt: "@res://world.aterrain")
            }
        }
        let restricted = try #require(try await limited.loadVolumeResources())
        await #expect(throws: AssetError.self) { try await restricted.loadPreparedMesh(operationID: operation.id) }
        await AssetsManager.destroyScope(scope); await AssetsManager.destroyScope(other)
    }

    private func writeVolumeOBJ(_ folder: URL, offset: Float, operation: TerrainVolumeOperation) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let positions: [Vector3] = [[-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1], [-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1]]
        var text = positions.map { "v \($0.x + offset) \($0.y) \($0.z)" }.joined(separator: "\n") + "\n"
        text += "f 1 4 3 2\nf 5 6 7 8\nf 1 2 6 5\nf 4 8 7 3\nf 1 5 8 4\nf 2 3 7 6\n"
        try Data(text.utf8).write(to: folder.appendingPathComponent("solid.obj"))
        try TerrainVolumeDocumentAsset(cellSize: 0.5, operations: [operation]).encodedData().write(to: folder.appendingPathComponent("solid.atvolume"))
        try TerrainManifestAsset(volumeFileName: "solid.atvolume").encodedData().write(to: folder.appendingPathComponent("world.aterrain"))
    }
}
