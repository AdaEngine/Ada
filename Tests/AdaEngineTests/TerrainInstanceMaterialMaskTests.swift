@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Mesh erase respects native rule masks and inverse history restores exact placement rows", arguments: [UInt16(7), UInt16(12)])
    func terrainMaterialFilteredErase(layer: UInt16) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try terrainGLTFDocument(normals: 3).write(to: directory.appendingPathComponent("prop.gltf"))
        let palette = TerrainMaterialPalette(
            layers: [.init(id: 7, name: "Grass"), .init(id: 12, name: "Masked rock")],
            fallbackLayerID: 7,
            rules: [.init(layerID: 12, maskID: 4)]
        )
        var masks: [TerrainRegionRuleMaskSample] = []
        for z in 0..<64 {
            for x in 0..<32 { masks.append(.init(x: UInt8(x), z: UInt8(z), maskID: 4, value: 1)) }
        }
        let rows = try [
            TerrainRegionInstance(id: 1, prototypeID: 17, localPosition: [20, 1, 20], flags: []),
            TerrainRegionInstance(id: 2, prototypeID: 17, localPosition: [40, 1, 20], flags: []),
        ]
        let region = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0)], pages: [], instances: rows, ruleMasks: masks)
        let file = directory.appendingPathComponent("world.aterrain")
        _ = try await AssetsManager.saveTerrainRegions([region], manifest: .init(meshPrototypes: [.init(id: 17, assetPath: "prop.gltf")], materials: palette), at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Masked erase") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let original = try #require(try storage.regionAsset(at: .init(x: 0, z: 0))).instances
        var settings = TerrainInstanceBrushSettings(prototypeID: 17, operation: .erase, radius: 20)
        settings.shape = .hardRound
        settings.materialLayerID = layer
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: .init(settings: settings, points: [.init(position: [30, 0, 20], time: 0)]))
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
        #expect(try storage.regionAsset(at: .init(x: 0, z: 0))?.instances.map(\.id) == [layer == 12 ? UInt64(2) : UInt64(1)])
        let delta = try #require(owner.components[Terrain3DEditStatus.self]?.delta)
        owner.components[Terrain3DEdit.self] = .init(storage: storage, undoing: delta)
        await settle(app)
        #expect(try storage.regionAsset(at: .init(x: 0, z: 0))?.instances == original)
    }

    @Test("Material rule evaluation is charged to the brush budget and rejection preserves the generation")
    func terrainMaterialFilterVisitBudget() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try terrainGLTFDocument(normals: 3).write(to: directory.appendingPathComponent("prop.gltf"))
        let palette = TerrainMaterialPalette(layers: [.init(id: 7, name: "Grass")], fallbackLayerID: 7, rules: Array(repeating: .init(layerID: 7), count: 128))
        let region = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0), .init(x: 1, z: 0), .init(x: 0, z: 1), .init(x: 1, z: 1)], pages: [])
        let file = directory.appendingPathComponent("world.aterrain")
        _ = try await AssetsManager.saveTerrainRegions([region], manifest: .init(meshPrototypes: [.init(id: 17, assetPath: "prop.gltf")], materials: palette), at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Bounded material filter") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let revision = storage.revision, originalBuffers = try buffers(owner)
        var settings = TerrainInstanceBrushSettings(prototypeID: 17, radius: 60, density: 1)
        settings.shape = .hardRound
        settings.minimumDistance = 1
        settings.materialLayerID = 7
        let points = [TerrainBrushPoint(position: [64, 0, 64], time: 0)]
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: .init(settings: settings, points: points))
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .failed)
        #expect(owner.components[Terrain3DEditStatus.self]?.error?.contains("visit budget") == true)
        #expect(storage.revision == revision)
        #expect(try storage.regionAsset(at: .init(x: 0, z: 0))?.instances.isEmpty == true)
        #expect(try buffers(owner) == originalBuffers)
        settings.materialLayerID = nil
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: .init(settings: settings, points: points))
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
        #expect(try storage.regionAsset(at: .init(x: 0, z: 0))?.instances.isEmpty == false)
    }
}
