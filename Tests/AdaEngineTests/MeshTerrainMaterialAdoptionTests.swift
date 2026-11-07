@_spi(Internal) @testable import AdaApp
import AdaAssets
import AdaECS
import AdaGeometry
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaTransform
import Foundation
import Math
import Testing

@MainActor @Suite("Mesh terrain material adoption", .serialized)
struct MeshTerrainMaterialAdoptionTests {
    @Test("A palette-only resource generation replaces the materials at the same world boundary as its URI",
          .enabled(if: TriangleMeshBoolean.isAvailable))
    func meshTerrainAdoptsPaletteWithoutRebuildingQueries() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeshPaletteAdoption-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ground = try TriangleSurface.ground(size: [8, 8], cells: 4)
        let asset = try await MeshTerrainDocumentAsset(document: .init(sections: [.init(surface: ground, closure: .ground(bottomHeight: -4))])).compiling()
        try asset.encodedData().write(to: directory.appendingPathComponent("ground.atmesh"))
        let original = directory.appendingPathComponent("ground.aterrain"), painted = directory.appendingPathComponent("palette.aterrain")
        let palette = TerrainMaterialPalette(layers: [.init(id: 21, name: "Grass", tint: [0.3, 0.7, 0.4, 1])], fallbackLayerID: 21)
        try TerrainManifestAsset(meshDocumentFileName: "ground.atmesh").encodedData().write(to: original)
        try TerrainManifestAsset(materials: palette, meshDocumentFileName: "ground.atmesh").encodedData().write(to: painted)
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        let owner = app.main.spawn("Ground") { Transform(); Terrain3DSource(source: original.path, generatesCollision: false, queries: .init()) }
        func settle(when finished: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(12))
            while !finished(), ContinuousClock.now < deadline {
                await app.main.runScheduler(.preUpdate)
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(finished())
        }
        try await settle { owner.components[Terrain3DSourceStatus.self]?.isReady == true }
        let coordinate = TerrainTileCoordinate(x: 0, z: 0)
        let initial = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.queries?.tileGeneration(at: coordinate))
        let key = try asset.authoringKey()
        for (file, hasPalette) in [(painted, true), (original, false)] {
            let edit = MeshTerrain3DEdit(expectedInputKey: key, candidate: asset, adoptionManifest: file.path)
            owner.components[MeshTerrain3DEdit.self] = edit
            try await settle {
                guard let status = owner.components[MeshTerrain3DEditStatus.self], status.id == edit.id else { return false }
                return status.phase != .pending
            }
            #expect(owner.components[MeshTerrain3DEditStatus.self]?.phase == .applied)
            #expect(owner.components[Terrain3DSource.self]?.source == file.path)
            let mesh = try #require(owner.children.compactMap { $0.components[Mesh3DComponent.self] }.first)
            let material = try #require(mesh.materials.first as? PBRMaterial)
            #expect((material.terrainBindings != nil) == hasPalette)
            #expect(owner.components[MeshTerrain3DSourceSurface.self]?.queries?.tileGeneration(at: coordinate) == initial)
            if owner.components[MeshTerrain3DEditStatus.self]?.phase != .applied { break }
        }
    }
}
