@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Mesh material filters respect rules/paint and reject missing layers atomically", arguments: [false, true], [UInt16(7), UInt16(12), UInt16(999)])
    func terrainMeshMaterialFilter(painted: Bool, layer: UInt16) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try terrainGLTFDocument(normals: 3).write(to: directory.appendingPathComponent("prop.gltf"))
        let palette = TerrainMaterialPalette(
            layers: [.init(id: 7, name: "Grass"), .init(id: 12, name: "Rock")],
            fallbackLayerID: 7,
            rules: [.init(layerID: 12, height: .init(minimum: 32, maximum: 100, transition: 0))]
        )
        var surface: [TerrainRegionSurfaceSample] = []
        if painted {
            for z in 0..<64 {
                for x in 0..<64 {
                    surface.append(.init(x: UInt8(x), z: UInt8(z), layerIDs: [12, 0, 0, 0], weights: [1, 0, 0, 0], overrideStrength: 1))
                }
            }
        }
        let region = TerrainRegionAsset(
            x: 0,
            z: 0,
            tiles: [.init(x: 0, z: 0)],
            pages: [.init(x: 0, z: 0, samples: (0..<4_096).map { Float($0 % 64) })],
            surface: surface
        )
        let file = directory.appendingPathComponent("world.aterrain")
        _ = try await AssetsManager.saveTerrainRegions(
            [region], manifest: .init(meshPrototypes: [.init(id: 17, assetPath: "prop.gltf")], materials: palette), at: file.path
        )
        let app = try await makeApp()
        let owner = app.main.spawn("Filtered mesh brush") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let originalBuffers = try buffers(owner), revision = storage.revision
        var settings = TerrainInstanceBrushSettings(prototypeID: 17, radius: 8, density: 4)
        settings.shape = .hardRound
        settings.minimumDistance = 1
        settings.materialLayerID = layer
        settings.minimumMaterialWeight = 0.75
        let stroke = TerrainInstanceBrushStroke(settings: settings, points: [.init(position: [32, 32, 20], time: 0)])
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: stroke)
        await settle(app)
        let rows = try #require(try storage.regionAsset(at: .init(x: 0, z: 0))).instances
        if layer == 999 {
            #expect(owner.components[Terrain3DEditStatus.self]?.phase == .failed)
            #expect(owner.components[Terrain3DEditStatus.self]?.error?.contains("layer") == true)
            #expect(rows.isEmpty && storage.revision == revision)
            #expect(try buffers(owner) == originalBuffers)
            return
        }
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
        if painted && layer == 7 {
            #expect(rows.isEmpty)
        } else {
            try #require(rows.count > 5)
            if !painted {
                #expect(rows.allSatisfy { layer == 7 ? $0.localPosition.x < 32 : $0.localPosition.x > 31 })
            } else {
                #expect(rows.contains { $0.localPosition.x < 30 } && rows.contains { $0.localPosition.x > 34 })
            }
        }
        let delta = try #require(owner.components[Terrain3DEditStatus.self]?.delta)
        owner.components[Terrain3DEdit.self] = .init(storage: storage, undoing: delta)
        await settle(app)
        #expect(try storage.regionAsset(at: .init(x: 0, z: 0))?.instances.isEmpty == true)
    }
}
