@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
@testable import AdaScene
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Saved rule masks and explicit paint overrides resolve canonical material fields across tile boundaries")
    func terrainSourceSurfaceFields() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let palette = TerrainMaterialPalette(
            layers: [.init(id: 7, name: "Red"), .init(id: 12, name: "Blue")],
            fallbackLayerID: 7,
            rules: [.init(layerID: 7), .init(layerID: 12, maskID: 9)]
        )
        let region = TerrainRegionAsset(
            x: 0,
            z: 0,
            tiles: [.init(x: 0, z: 0), .init(x: 1, z: 0)],
            pages: [],
            surface: [
                .init(x: 32, z: 32, layerIDs: [12, 0, 0, 0], weights: [1, 0, 0, 0], overrideStrength: 1),
                .init(x: 64, z: 32, layerIDs: [12, 0, 0, 0], weights: [1, 0, 0, 0], overrideStrength: 0.25),
            ],
            ruleMasks: [.init(x: 64, z: 32, maskID: 9, value: 1), .init(x: 96, z: 32, maskID: 9, value: 0.5)]
        )
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions([region], manifest: .init(materials: palette), at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Painted terrain") {
            Transform()
            Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
        }
        await settle(app)
        try #require(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        let state = try #require(owner.components[TerrainSourceState.self])
        let left = try #require(state.tiles[.init(x: 0, z: 0)]?.descriptor)
        let right = try #require(state.tiles[.init(x: 1, z: 0)]?.descriptor)
        let ids = try #require(left[TerrainSourceMaterials.layerIDs]).elements
        let weights = try #require(left[TerrainSourceMaterials.weights]).elements
        let rightIDs = try #require(right[TerrainSourceMaterials.layerIDs]).elements
        let rightWeights = try #require(right[TerrainSourceMaterials.weights]).elements
        func weight(_ id: UInt16, ids: Vector4, weights: Vector4) -> Float {
            (0..<4).reduce(Float(0)) { $0 + (ids[$1] == Float(id) ? weights[$1] : 0) }
        }
        #expect(weight(7, ids: ids[0], weights: weights[0]) == 1)
        let full = 32 * 65 + 32, edge = 32 * 65 + 64, oppositeEdge = 32 * 65
        #expect(weight(12, ids: ids[full], weights: weights[full]) == 1)
        #expect(abs(weight(12, ids: ids[edge], weights: weights[edge]) - 0.625) < 0.0001)
        #expect(ids[edge] == rightIDs[oppositeEdge] && weights[edge] == rightWeights[oppositeEdge])
        #expect(abs(weight(12, ids: rightIDs[full], weights: rightWeights[full]) - Float(1) / 3) < 0.0001)
        let saved = try #require(try state.storage?.regionAsset(at: .init(x: 0, z: 0)))
        #expect(saved.surface == region.surface && saved.ruleMasks == region.ruleMasks)
    }

    @Test("An active saved paint ID absent from the palette rejects publication instead of silently discarding paint")
    func terrainSourceSurfaceUnknownLayer() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let region = TerrainRegionAsset(
            x: 0,
            z: 0,
            tiles: [.init(x: 0, z: 0)],
            pages: [],
            surface: [.init(x: 32, z: 32, layerIDs: [35, 0, 0, 0], weights: [1, 0, 0, 0], overrideStrength: 1)]
        )
        let file = directory.appendingPathComponent("world.aterrain")
        let palette = TerrainMaterialPalette(layers: [.init(id: 7, name: "Only layer")], fallbackLayerID: 7)
        try await AssetsManager.saveTerrainRegions([region], manifest: .init(materials: palette), at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Invalid painted terrain") {
            Transform()
            Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
        }
        await settle(app)
        let status = try #require(owner.components[Terrain3DSourceStatus.self])
        #expect(!status.isReady && status.error != nil)
        #expect(owner.components[Terrain3DSourceSurface.self] == nil)
    }
}
