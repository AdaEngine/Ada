@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Full canonical layer coverage passes an exact threshold of one at fractional placement coordinates")
    func terrainMaterialFilterFullCoverageThreshold() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try terrainGLTFDocument(normals: 3).write(to: directory.appendingPathComponent("prop.gltf"))
        let row = try TerrainRegionInstance(id: 1, prototypeID: 17, localPosition: [0.1, 1, 0.2], flags: [])
        let palette = TerrainMaterialPalette(layers: [.init(id: 7, name: "Grass")], fallbackLayerID: 7)
        let region = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0)], pages: [], instances: [row])
        let file = directory.appendingPathComponent("world.aterrain")
        _ = try await AssetsManager.saveTerrainRegions([region], manifest: .init(meshPrototypes: [.init(id: 17, assetPath: "prop.gltf")], materials: palette), at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Exact material threshold") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        var settings = TerrainInstanceBrushSettings(prototypeID: 17, operation: .erase, radius: 0.5)
        settings.shape = .hardRound
        settings.materialLayerID = 7
        settings.minimumMaterialWeight = 1
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: .init(settings: settings, points: [.init(position: [0.1, 0, 0.2], time: 0)]))
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
        #expect(try storage.regionAsset(at: .init(x: 0, z: 0))?.instances.isEmpty == true)
    }
}
