@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
@testable import AdaScene
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    func finishSurfaceEdit(_ app: AppWorlds, owner: Entity, id: UUID) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(15))
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            if let status = owner.components[Terrain3DEditStatus.self], status.id == id, status.phase != .pending {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Surface edit did not finish before its bounded deadline")
    }

    @Test("Erasing valid native tint and masks without a palette remains exactly undoable")
    func terrainSurfaceEditEdgeNoPaletteUndo() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let point = TerrainGridPoint(x: 10, z: 10)
        let original = TerrainRegionSurfaceSample(x: 10, z: 10, tint: [0.25, 0.5, 0.75, 1], tintStrength: 1, roughness: 0.2, roughnessStrength: 0.5)
        let mask = TerrainRegionRuleMaskSample(x: 10, z: 10, maskID: 9, value: 0.25)
        let region = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0)], pages: [], surface: [original], ruleMasks: [mask])
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions([region], manifest: .init(), at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Native unassigned surface") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        try #require(storage.paint(atSample: point) == original.paint && storage.ruleMask(atSample: point, id: 9) == 0.25)
        let erase = Terrain3DEdit(storage: storage, surface: [.init(point: point, paint: nil)], masks: [.init(point: point, maskID: 9, value: 0)])
        owner.components[Terrain3DEdit.self] = erase
        try await finishSurfaceEdit(app, owner: owner, id: erase.id)
        let erased = try #require(owner.components[Terrain3DEditStatus.self])
        try #require(erased.phase == .applied && storage.paint(atSample: point) == nil && storage.ruleMask(atSample: point, id: 9) == 0)
        let delta = try #require(erased.delta)
        let undo = Terrain3DEdit(storage: storage, undoing: delta)
        owner.components[Terrain3DEdit.self] = undo
        try await finishSurfaceEdit(app, owner: owner, id: undo.id)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
        #expect(storage.paint(atSample: point) == original.paint && storage.ruleMask(atSample: point, id: 9) == 0.25)
    }

    @Test("Rejected paint preserves the ready source, fallback resources and existing missing-map warnings")
    func terrainSurfaceEditEdgeRetainsWarnings() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let region = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0)], pages: [])
        let palette = TerrainMaterialPalette(layers: [.init(id: 7, name: "Missing map", albedoPath: "missing.png")], fallbackLayerID: 7)
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions([region], manifest: .init(materials: palette), at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Fallback painted terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
        }
        await settle(app)
        let initial = try #require(owner.components[Terrain3DSourceStatus.self])
        try #require(initial.isReady && initial.warnings.count == 1)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let originalBuffers = try buffers(owner), revision = storage.revision
        let paint = TerrainSurfacePaint(layerIDs: [35, 0, 0, 0], weights: [1, 0, 0, 0], overrideStrength: 1)
        let edit = Terrain3DEdit(storage: storage, surface: [.init(point: .init(x: 10, z: 10), paint: paint)])
        owner.components[Terrain3DEdit.self] = edit
        try await finishSurfaceEdit(app, owner: owner, id: edit.id)
        try #require(owner.components[Terrain3DEditStatus.self]?.phase == .failed)
        let status = try #require(owner.components[Terrain3DSourceStatus.self])
        #expect(status.isReady && status.error == nil && status.warnings == initial.warnings)
        #expect(try buffers(owner) == originalBuffers)
        #expect(storage.revision == revision && storage.paint(atSample: .init(x: 10, z: 10)) == nil)
    }
}
