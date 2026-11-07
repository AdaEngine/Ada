@_spi(Internal) @testable import AdaApp
@testable import AdaAssets
import AdaEngine
@testable import AdaScene
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Model root byte limits apply in the asset manager before invoking the model decoder")
    func terrainModelRootReadIsBounded() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await makeApp()
        let file = directory.appendingPathComponent("rock.gltf")
        var data = try terrainGLTFDocument(normals: 3)
        data.append(Data(repeating: 32, count: 65_536))
        try data.write(to: file)
        await #expect(throws: AssetError.self) {
            try await ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 4_096, maximumDecodedBytes: 65_536)) {
                _ = try await AssetsManager.loadFresh(ModelAsset3D.self, at: file.path)
            }
        }
    }

    @Test("Bounded model decoding uses provided root bytes without reopening the source file")
    func terrainModelReusesDecoderRootBytes() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await makeApp()
        let missing = directory.appendingPathComponent("already-read.gltf")
        let decoder = TextAssetDecoder(meta: AssetMeta(filePath: missing, queryParams: []), data: try terrainGLTFDocument(normals: 3))
        let model = try await ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 4_096, maximumDecodedBytes: 65_536)) {
            try await ModelAsset3D(from: decoder)
        }
        #expect(model.meshes.count == 1)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("Terrain palette caches retain scoped model read budgets across actor calls and forks")
    func terrainPaletteKeepsModelReadBudget() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await makeApp()
        let file = directory.appendingPathComponent("world.aterrain")
        let reference = TerrainMeshPrototypeReference(id: 17, assetPath: "rock.gltf")
        try await AssetsManager.saveTerrainRegions([], manifest: .init(meshPrototypes: [reference]), at: file.path)
        var data = try terrainGLTFDocument(normals: 3)
        data.append(Data(repeating: 32, count: 65_536))
        try data.write(to: directory.appendingPathComponent("rock.gltf"))
        let cache = try await ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 4_096, maximumDecodedBytes: 65_536)) {
            try await TerrainRegionCache.open(manifestAt: file.path)
        }
        await #expect(throws: AssetError.self) { _ = try await cache.loadPrototype(reference) }
        let fork = try await cache.fork(limits: .init())
        await #expect(throws: AssetError.self) { _ = try await fork.loadPrototype(reference) }
    }
}
