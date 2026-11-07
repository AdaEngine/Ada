@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
@testable import AdaScene
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Camera and LOD changes retain layer-paint fields without walking unchanged surface records")
    func terrainSourceSurfaceCoverageNoCameraWalks() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var samples: [TerrainRegionSurfaceSample] = []
        for z in 0..<128 {
            for x in 0..<128 {
                samples.append(.init(x: UInt8(x), z: UInt8(z), layerIDs: [7, 0, 0, 0], weights: [1, 0, 0, 0], overrideStrength: 1))
            }
        }
        let region = TerrainRegionAsset(
            x: 0,
            z: 0,
            tiles: [.init(x: 0, z: 0), .init(x: 1, z: 0), .init(x: 0, z: 1), .init(x: 1, z: 1)],
            pages: [],
            surface: samples
        )
        let palette = TerrainMaterialPalette(layers: [.init(id: 7, name: "Paint")], fallbackLayerID: 7)
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions([region], manifest: .init(materials: palette), at: file.path)
        let app = try await makeApp()
        var source = Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
        let owner = app.main.spawn("Large layer-painted surface") { Transform(); source }
        await settle(app)
        let initial = try #require(owner.components[TerrainSourceState.self])
        try #require(initial.storage?.surfaceSnapshot().sampleCount == 16_384 && initial.materialSampleEvaluationCount > 0)
        let coordinate = TerrainTileCoordinate(x: 0, z: 0)
        let original = try #require(initial.tiles[coordinate])
        let ids = try #require(original.descriptor[TerrainSourceMaterials.layerIDs])
        let identity = ObjectIdentifier(ids.buffer)
        source.maximumLOD = 6
        source.lodDistance = 32
        owner.components[Terrain3DSource.self] = source
        let camera = app.main.spawn("Paint LOD camera") { Transform(position: [0, 4, 0]); Camera() }
        var previousLevel = original.selection.level
        for distance: Float in [256, 10_000] {
            camera.components[Transform.self] = Transform(position: [distance, 4, 0])
            await settle(app)
            let state = try #require(owner.components[TerrainSourceState.self])
            let tile = try #require(state.tiles[coordinate])
            try #require(tile.selection.level > previousLevel)
            #expect(state.surfaceCoverageRowVisitCount == 0)
            #expect(state.materialSampleEvaluationCount == 0)
            #expect(ObjectIdentifier(try #require(tile.descriptor[TerrainSourceMaterials.layerIDs]).buffer) == identity)
            previousLevel = tile.selection.level
        }
    }
}
