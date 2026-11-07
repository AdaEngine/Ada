@_spi(Internal) @testable import AdaApp
import AdaEngine
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test(
        "Height-only edge and corner writes admit new canonical page regions before publishing",
        arguments: [
            (TerrainRegionTile(x: 3, z: 0), TerrainGridPoint(x: 256, z: 10)),
            (TerrainRegionTile(x: 0, z: 3), TerrainGridPoint(x: 10, z: 256)),
            (TerrainRegionTile(x: 3, z: 3), TerrainGridPoint(x: 256, z: 256)),
        ]
    )
    func heightEditsAdmitCanonicalBoundaryRegions(tile: TerrainRegionTile, point: TerrainGridPoint) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions([.init(x: 0, z: 0, tiles: [tile], pages: [])], manifest: .init(), at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumResidentRegions: 1, maximumLOD: 0)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let revision = storage.revision
        owner.components[Terrain3DEdit.self] = .init(storage: storage, updates: [.init(point: point, height: 4)])
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .failed)
        #expect(owner.components[Terrain3DEditStatus.self]?.error != nil)
        #expect(storage.revision == revision)
        #expect(storage.resourceCoordinates == [.init(x: 0, z: 0)])
        #expect(storage.height(atSample: point) == 0)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
    }
}
