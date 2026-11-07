@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
@testable import AdaScene
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("All surface brush families preserve other channels and Undo one shared-border gesture", arguments: TerrainSurfaceBrushOperation.allCases)
    func terrainSurfaceBrushChannels(operation: TerrainSurfaceBrushOperation) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = TerrainSurfacePaint(
            layerIDs: [7, 0, 0, 0],
            weights: [1, 0, 0, 0],
            overrideStrength: 0.5,
            tint: [0.3, 0.4, 0.5, 1],
            tintStrength: 0.5,
            roughness: 0.8,
            roughnessStrength: 0.5
        )
        let region = TerrainRegionAsset(
            x: 0,
            z: 0,
            tiles: [.init(x: 0, z: 0), .init(x: 1, z: 0)],
            pages: [],
            surface: [original.regionSample(x: 64, z: 32)],
            ruleMasks: [.init(x: 64, z: 32, maskID: 9, value: 0.25)]
        )
        let palette = TerrainMaterialPalette(layers: [.init(id: 7, name: "Base"), .init(id: 12, name: "Paint")], fallbackLayerID: 7)
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions([region], manifest: .init(materials: palette), at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Surface brush") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil, maximumTileUpdatesPerFrame: 1)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let revision = storage.revision, originalBuffers = try buffers(owner)
        let point = TerrainGridPoint(x: 64, z: 32)
        var settings = TerrainSurfaceBrushSettings(operation: operation, radius: 0.75, strength: 0.5)
        settings.shape = .hardRound; settings.layerID = 12; settings.maskID = 9
        settings.tint = [1, 0, 0, 1]; settings.roughness = 0.2
        let stroke = TerrainSurfaceBrushStroke(settings: settings, points: [.init(position: [64, 0, 32], time: 0)])
        let request = Terrain3DEdit(storage: storage, brush: stroke)
        owner.components[Terrain3DEdit.self] = request
        try await finishSurfaceEdit(app, owner: owner, id: request.id)
        let status = try #require(owner.components[Terrain3DEditStatus.self])
        try #require(status.phase == .applied)
        let paint = try #require(storage.paint(atSample: point))
        #expect(storage.revision == revision + 1)
        switch operation {
        case .paintLayer:
            #expect(paint.overrideStrength == 0.75 && paint.layerIDs.x == 12 && abs(paint.weights.x - 2 / Float(3)) < 0.0001)
        case .eraseLayer: #expect(paint.overrideStrength == 0.25)
        case .paintMask: #expect(storage.ruleMask(atSample: point, id: 9) == 0.625 && paint == original)
        case .paintTint:
            #expect(paint.tintStrength == 0.75 && abs(paint.tint.x - 23 / Float(30)) < 0.0001 && abs(paint.tint.y - 2 / Float(15)) < 0.0001)
        case .eraseTint: #expect(paint.tintStrength == 0.25)
        case .paintRoughness: #expect(paint.roughnessStrength == 0.75 && abs(paint.roughness - 0.4) < 0.0001)
        case .eraseRoughness: #expect(paint.roughnessStrength == 0.25)
        }
        if operation != .paintLayer && operation != .eraseLayer { #expect(paint.overrideStrength == original.overrideStrength && paint.layerIDs == original.layerIDs) }
        if operation != .paintTint && operation != .eraseTint { #expect(paint.tint == original.tint && paint.tintStrength == original.tintStrength) }
        if operation != .paintRoughness && operation != .eraseRoughness { #expect(paint.roughness == original.roughness && paint.roughnessStrength == original.roughnessStrength) }
        let delta = try #require(status.delta)
        #expect(delta.surfaceChanges.count + delta.maskChanges.count == 1)
        #expect(try buffers(owner) == originalBuffers)
        let undo = Terrain3DEdit(storage: storage, undoing: delta)
        owner.components[Terrain3DEdit.self] = undo
        try await finishSurfaceEdit(app, owner: owner, id: undo.id)
        #expect(storage.paint(atSample: point) == original && storage.ruleMask(atSample: point, id: 9) == 0.25)
        #expect(try buffers(owner) == originalBuffers)
    }
}
