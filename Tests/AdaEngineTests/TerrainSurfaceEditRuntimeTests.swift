@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
@testable import AdaScene
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Paint and masks publish atomically with compact Undo and native saving")
    func terrainSurfaceEditAtomicUndo() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authored = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0), .init(x: 1, z: 0)], pages: [])
        let palette = TerrainMaterialPalette(
            layers: [.init(id: 7, name: "Base"), .init(id: 12, name: "Paint")],
            fallbackLayerID: 7,
            rules: [.init(layerID: 7), .init(layerID: 12, maskID: 9)]
        )
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions([authored], manifest: .init(materials: palette), at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Live painted terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil, maximumTileUpdatesPerFrame: 1)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let revision = storage.revision
        let point = TerrainGridPoint(x: 64, z: 32)
        let paint = TerrainSurfacePaint(
            layerIDs: [12, 0, 0, 0],
            weights: [1, 0, 0, 0],
            overrideStrength: 0.25,
            tint: [0.25, 0.5, 0.75, 1],
            tintStrength: 0.5,
            roughness: 0.2,
            roughnessStrength: 0.5
        )
        let request = Terrain3DEdit(
            storage: storage,
            surface: [.init(point: point, paint: paint)],
            masks: [.init(point: point, maskID: 9, value: 1)]
        )
        owner.components[Terrain3DEdit.self] = request
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(15))
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            if owner.components[Terrain3DEditStatus.self]?.phase != .pending,
                owner.components[Terrain3DEditStatus.self]?.id == request.id { break }
            #expect(storage.paint(atSample: point) == nil && storage.ruleMask(atSample: point, id: 9) == 0)
            try await Task.sleep(for: .milliseconds(1))
        }
        let status = try #require(owner.components[Terrain3DEditStatus.self])
        try #require(status.phase == .applied && status.id == request.id)
        let delta = try #require(status.delta)
        #expect(storage.revision == revision + 1)
        #expect(storage.paint(atSample: point) == paint && storage.ruleMask(atSample: point, id: 9) == 1)
        #expect(delta.changes.isEmpty && delta.instanceChanges.isEmpty && delta.surfaceChanges.count == 1 && delta.maskChanges.count == 1)
        let state = try #require(owner.components[TerrainSourceState.self])
        let tile = try #require(state.tiles[.init(x: 0, z: 0)]?.descriptor)
        let ids = try #require(tile[TerrainSourceMaterials.layerIDs]).elements[32 * 65 + 64]
        let weights = try #require(tile[TerrainSourceMaterials.weights]).elements[32 * 65 + 64]
        #expect(ids.x == 12 && abs(weights.x - 0.625) < 0.0001)
        owner.components[Terrain3DSave.self] = .init(storage: storage)
        await finishSave(app, owner: owner)
        try #require(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        let manifest = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        let ref = try #require(manifest.heightRegions.first)
        let saved = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: directory.appendingPathComponent(ref.fileName).path)
        #expect(saved.surface.first?.paint == paint && saved.ruleMasks.first?.value == 1)
        owner.components[Terrain3DEdit.self] = .init(storage: storage, undoing: delta)
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
        #expect(storage.paint(atSample: point) == nil && storage.ruleMask(atSample: point, id: 9) == 0)
    }
}
