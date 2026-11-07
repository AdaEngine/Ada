@_spi(Internal) @testable import AdaApp
import AdaEngine
@testable import AdaScene
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Acknowledging an immutable save keeps later surface and mask changes dirty", arguments: [false, true])
    func terrainSourceSurfacePersistenceAck(maskOnly: Bool) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = TerrainRegionSurfaceSample(x: 10, z: 10, tint: [0.25, 0.5, 0.75, 1], tintStrength: 1, roughness: 0.2, roughnessStrength: 0.5)
        let originalMask = TerrainRegionRuleMaskSample(x: 10, z: 10, maskID: 9, value: 0.25)
        let asset = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0)], pages: [], surface: [original], ruleMasks: [originalMask])
        let file = directory.appendingPathComponent("world.aterrain")
        let palette = TerrainMaterialPalette(layers: [.init(id: 7, name: "Base")], fallbackLayerID: 7)
        try await AssetsManager.saveTerrainRegions([asset], manifest: .init(materials: palette), at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Save-race terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        try storage.setHeight(6, at: .init(x: 10, z: 10))
        await settle(app)
        let residency = try #require(owner.components[TerrainSourceState.self]?.residency)
        let snapshot = try residency.saveSnapshot(.init(storage: storage))
        let coordinate = TerrainRegionCoordinate(x: 0, z: 0)
        let current = try #require(try storage.regionAsset(at: coordinate))
        let laterPaint = maskOnly ? original : TerrainRegionSurfaceSample(x: 10, z: 10, tint: [0.25, 0.5, 0.75, 1], tintStrength: 0.5, roughness: 0.2, roughnessStrength: 0.5)
        let laterMask = maskOnly ? TerrainRegionRuleMaskSample(x: 10, z: 10, maskID: 9, value: 0.75) : originalMask
        let changed = TerrainRegionAsset(x: 0, z: 0, tiles: current.tiles, pages: current.pages, surface: [laterPaint], ruleMasks: [laterMask])
        // The real COW residency path models a later low-level author edit while disk writes the captured generation.
        let candidate = try storage.residencySnapshot(regions: [changed], visible: residency.visible, expectedRevision: storage.revision)
        try storage.commitResidency(candidate, expectedRevision: storage.revision)
        try #require(storage.revision > snapshot.revision)
        try await AssetsManager.saveTerrainRegions(snapshot.regions, manifest: residency.cache.manifest, at: file.path)
        let cache = try await TerrainRegionCache.open(manifestAt: file.path)
        let acknowledged = try residency.acknowledging(snapshot, cache: cache)
        let pending = try #require(acknowledged.overrides[coordinate])
        #expect(pending.surface == [laterPaint] && pending.ruleMasks == [laterMask])
        let next = try acknowledged.saveSnapshot(.init(storage: storage))
        #expect(next.regions.first?.surface == [laterPaint] && next.regions.first?.ruleMasks == [laterMask])
        let savedManifest = await cache.manifest
        let reference = try #require(savedManifest.heightRegions.first)
        let written = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: directory.appendingPathComponent(reference.fileName).path)
        #expect(written.surface == [original] && written.ruleMasks == [originalMask] && written.pages.first?.samples[650] == 6)
    }
}
