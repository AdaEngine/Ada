@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
@testable import AdaScene
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Surface-only gestures reuse geometry and collision while still replacing material fields")
    func terrainSurfaceEditReusesGeometry() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let region = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0), .init(x: 1, z: 0)], pages: [])
        let palette = TerrainMaterialPalette(layers: [.init(id: 7, name: "Base"), .init(id: 12, name: "Paint")], fallbackLayerID: 7)
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions([region], manifest: .init(materials: palette), at: file.path)
        let app = try await makeApp(physics: true)
        let owner = app.main.spawn("Geometry-preserving surface") {
            Transform(); Terrain3DSource(source: file.path, maximumLOD: 0, streamingRadius: nil, maximumTileUpdatesPerFrame: 1)
        }
        await settle(app)
        await app.main.runScheduler(.physicsSync)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let before = try #require(owner.components[TerrainSourceState.self])
        let originalBuffers = try buffers(owner), originalColliders = before.tiles.mapValues { $0.collider }
        let completeColliders = originalColliders.count == 2 && originalColliders.values.allSatisfy { $0 != nil }
        try #require(completeColliders)
        let coordinate = TerrainTileCoordinate(x: 0, z: 0)
        let tile = try #require(before.tiles[coordinate])
        let entity = try #require(app.main.getEntityByID(tile.entity))
        let oldMaterial = try #require(entity.components[Mesh3DComponent.self]?.materials.first as? PBRMaterial)
        let point = TerrainGridPoint(x: 64, z: 32)
        let paint = TerrainSurfacePaint(layerIDs: [12, 0, 0, 0], weights: [1, 0, 0, 0], overrideStrength: 1, roughness: 0.2, roughnessStrength: 0.5)
        let request = Terrain3DEdit(storage: storage, surface: [.init(point: point, paint: paint)])
        owner.components[Terrain3DEdit.self] = request
        try await finishSurfaceEdit(app, owner: owner, id: request.id)
        let status = try #require(owner.components[Terrain3DEditStatus.self])
        try #require(status.phase == .applied && storage.paint(atSample: point) == paint)
        await app.main.runScheduler(.physicsSync)
        let state = try #require(owner.components[TerrainSourceState.self])
        #expect(try buffers(owner) == originalBuffers)
        let paintedColliders = state.tiles.mapValues { $0.collider }
        #expect(paintedColliders == originalColliders)
        let material = try #require(entity.components[Mesh3DComponent.self]?.materials.first as? PBRMaterial)
        #expect(material !== oldMaterial && material.terrainBindings != nil)
        let descriptor = try #require(state.tiles[coordinate]?.descriptor)
        #expect(descriptor[TerrainSourceMaterials.layerIDs]?.elements[32 * 65 + 64].x == 12)
        let delta = try #require(status.delta)
        let undo = Terrain3DEdit(storage: storage, undoing: delta)
        owner.components[Terrain3DEdit.self] = undo
        try await finishSurfaceEdit(app, owner: owner, id: undo.id)
        #expect(try buffers(owner) == originalBuffers)
        let undoneColliders = owner.components[TerrainSourceState.self]?.tiles.mapValues { $0.collider }
        #expect(undoneColliders == originalColliders)
        let sculpt = Terrain3DEdit(storage: storage, updates: [.init(point: point, height: 5)])
        owner.components[Terrain3DEdit.self] = sculpt
        try await finishSurfaceEdit(app, owner: owner, id: sculpt.id)
        try #require(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
        #expect(try buffers(owner) != originalBuffers)
        let sculptedColliders = owner.components[TerrainSourceState.self]?.tiles.mapValues { $0.collider }
        #expect(sculptedColliders != originalColliders)
    }
}
