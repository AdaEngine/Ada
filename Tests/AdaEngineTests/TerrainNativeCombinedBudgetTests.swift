@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
@testable import AdaScene
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Authoring refuses a region that would exceed the combined native byte limit", arguments: ["height", "mask", "instances"])
    func terrainNativeCombinedEditBudget(kind: String) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var surface: [TerrainRegionSurfaceSample] = [], instances: [TerrainRegionInstance] = []
        for z in 0..<256 {
            for x in 0..<256 { surface.append(.init(x: UInt8(x), z: UInt8(z), tintStrength: 1)) }
        }
        for index in 0..<63_000 {
            instances.append(try .init(
                id: UInt64(index), prototypeID: 0, localPosition: [Float(index % 256) + 0.5, 0, Float(index / 256) + 0.5], flags: []
            ))
        }
        var pages: [TerrainRegionHeightPage] = [], tiles: [TerrainRegionTile] = []
        for index in 0..<9 {
            var values = [Float](repeating: 0, count: 4_096)
            values[0] = 1
            pages.append(.init(x: UInt8(index % 4), z: UInt8(index / 4), samples: values))
        }
        for z in 0..<4 { for x in 0..<4 { tiles.append(.init(x: UInt8(x), z: UInt8(z))) } }
        let region = TerrainRegionAsset(x: 0, z: 0, tiles: tiles, pages: pages, instances: instances, surface: surface)
        let originalBytes = try region.encodedData()
        try #require(originalBytes.count < 8 * 1_024 * 1_024 && originalBytes.count > 8 * 1_024 * 1_024 - 16_384)
        try terrainGLTFDocument(normals: 3).write(to: directory.appendingPathComponent("rock.gltf"))
        let palette = TerrainMaterialPalette(layers: [.init(id: 7, name: "Base")], fallbackLayerID: 7)
        let manifest = TerrainManifestAsset(meshPrototypes: [.init(id: 0, assetPath: "rock.gltf")], materials: palette)
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions([region], manifest: manifest, at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Near-limit authored terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let revision = storage.revision, originalBuffers = try buffers(owner)
        let original = try #require(try storage.regionAsset(at: .init(x: 0, z: 0)))
        let request: Terrain3DEdit
        if kind == "height" {
            request = .init(storage: storage, updates: [.init(point: .init(x: 64, z: 128), height: 2)])
        } else if kind == "mask" {
            let masks = (0..<2_000).map { TerrainRuleMaskUpdate(point: .init(x: $0 % 64, z: $0 / 64), maskID: 9, value: 0.5) }
            request = .init(storage: storage, surface: [], masks: masks)
        } else {
            let cell = TerrainTileCoordinate(x: 0, z: 0)
            let previous = storage.instanceCellSnapshot()[cell]?.records ?? []
            let added = try (63_000..<63_256).map { try TerrainRegionInstance(id: UInt64($0), prototypeID: 0, localPosition: [1.5, 0, 1.5], flags: []) }
            request = .init(storage: storage, instances: [.init(coordinate: cell, previous: previous, instances: previous + added)])
        }
        owner.components[Terrain3DEdit.self] = request
        try await finishSurfaceEdit(app, owner: owner, id: request.id)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .failed)
        #expect(storage.revision == revision)
        #expect(try buffers(owner) == originalBuffers)
        let retained = try #require(try storage.regionAsset(at: .init(x: 0, z: 0)))
        #expect(retained.pages == original.pages && retained.instances == original.instances && retained.surface == original.surface && retained.ruleMasks == original.ruleMasks)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
    }
}
