@_spi(Internal) @testable import AdaApp
import AdaEngine
@testable import AdaScene
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Sculpting, runtime save and streaming preserve every native surface channel", arguments: [false, true])
    func terrainSourceSurfacePersistence(streamBeforeSave: Bool) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paint = TerrainRegionSurfaceSample(
            x: 10,
            z: 10,
            layerIDs: [12, 0, 0, 0],
            weights: [1, 0, 0, 0],
            overrideStrength: 0.5,
            tint: [0.25, 0.5, 0.75, 1],
            tintStrength: 0.5,
            roughness: 0.2,
            roughnessStrength: 0.5
        )
        let mask = TerrainRegionRuleMaskSample(x: 12, z: 12, maskID: 9, value: 0.25)
        let first = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0)], pages: [], surface: [paint], ruleMasks: [mask])
        let distant = TerrainRegionAsset(x: 4, z: 0, tiles: [.init(x: 0, z: 0)], pages: [])
        let palette = TerrainMaterialPalette(layers: [.init(id: 7, name: "Base"), .init(id: 12, name: "Paint")], fallbackLayerID: 7)
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions([first, distant], manifest: .init(materials: palette), at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Persistent painted terrain") {
            Transform()
            Terrain3DSource(source: file.path, generatesCollision: false, maximumResidentHeightBytes: 32_768, maximumLOD: 0, streamingRadius: 20)
        }
        let camera = app.main.spawn("Paint residency camera") { Transform(position: [10, 20, 10]); Camera() }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        try #require(try storage.regionAsset(at: .init(x: 0, z: 0))?.surface == [paint])
        try storage.setHeight(6, at: .init(x: 10, z: 10))
        await settle(app)
        if streamBeforeSave {
            camera.components[Transform.self] = Transform(position: [1_034, 20, 10])
            await settle(app)
            try #require(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
            let hidden = try #require(try storage.regionAsset(at: .init(x: 0, z: 0)))
            #expect(hidden.tiles.isEmpty && hidden.surface == [paint] && hidden.ruleMasks == [mask])
        }
        owner.components[Terrain3DSave.self] = .init(storage: storage)
        await finishSave(app, owner: owner)
        try #require(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        let manifest = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        let ref = try #require(manifest.heightRegions.first { $0.x == 0 })
        let saved = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: directory.appendingPathComponent(ref.fileName).path)
        #expect(saved.surface == [paint] && saved.ruleMasks == [mask] && saved.tiles == first.tiles)
        #expect(saved.pages.first?.samples[650] == 6)
        camera.components[Transform.self] = Transform(position: [10, 20, 10])
        await settle(app)
        let restored = try #require(try storage.regionAsset(at: .init(x: 0, z: 0)))
        #expect(restored.surface == [paint] && restored.ruleMasks == [mask])
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == 6)
    }

    @Test("Clearing the last boundary height page cannot delete a region that still holds shared paint or masks")
    func terrainSourceSurfacePersistenceDataOnly() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var heights = [Float](repeating: 0, count: 4_096)
        heights[640] = 6
        let paint = TerrainRegionSurfaceSample(x: 0, z: 10, tintStrength: 1, roughness: 0.2, roughnessStrength: 0.5)
        let mask = TerrainRegionRuleMaskSample(x: 0, z: 10, maskID: 9, value: 1)
        let left = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 3, z: 0)], pages: [])
        let boundary = TerrainRegionAsset(
            x: 1,
            z: 0,
            tiles: [],
            pages: [.init(x: 0, z: 0, samples: heights)],
            surface: [paint],
            ruleMasks: [mask]
        )
        let palette = TerrainMaterialPalette(layers: [.init(id: 7, name: "Base")], fallbackLayerID: 7)
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions([left, boundary], manifest: .init(materials: palette), at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Boundary-painted terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        try #require(storage.height(atSample: .init(x: 256, z: 10)) == 6)
        try storage.setHeight(0, at: .init(x: 256, z: 10))
        await settle(app)
        owner.components[Terrain3DSave.self] = .init(storage: storage)
        await finishSave(app, owner: owner)
        try #require(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        let manifest = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        let reference = try #require(manifest.heightRegions.first { $0.x == 1 })
        let saved = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: directory.appendingPathComponent(reference.fileName).path)
        #expect(saved.tiles.isEmpty && saved.pages.isEmpty && saved.surface == [paint] && saved.ruleMasks == [mask])
    }
}
