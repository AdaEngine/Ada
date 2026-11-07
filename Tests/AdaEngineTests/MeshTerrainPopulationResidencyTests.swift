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

@MainActor @Suite("Mesh Terrain population residency", .serialized)
struct MeshTerrainPopulationResidencyTests {
    @Test("Stacked population sheets keep distinct local instance batches")
    func meshPopulationKeepsVerticalCellsSeparate() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaPopulationCells-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let voxel = VOXModel(sizeX: 1, sizeY: 1, sizeZ: 1, voxels: [.init(x: 0, y: 0, z: 0, colorIndex: 1)])
        try VOXWriter().encode(model: voxel, palette: .fallback).write(to: directory.appendingPathComponent("plant.vox"))
        let bottom = MeshTerrainBaseSection(surface: try .ground(size: [12, 12], cells: 4), closure: .ground(bottomHeight: -8))
        let top = MeshTerrainBaseSection(surface: try TriangleSurface.ground(size: [12, 12], cells: 4).transformed(by: .init(translation: [0, 40, 0])),
                                         closure: .ground(bottomHeight: 32))
        let placements: [MeshTerrainPlacement] = [
            .init(id: 11, prototypeID: 1, transform: .init(translation: [0, 0, 0])),
            .init(id: 22, prototypeID: 1, transform: .init(translation: [0, 40, 0]))
        ]
        let asset = try await MeshTerrainDocumentAsset(document: .init(sections: [bottom, top]), manualPlacements: placements).compiling()
        let manifest = directory.appendingPathComponent("world.aterrain")
        try asset.encodedData().write(to: directory.appendingPathComponent("ground.atmesh"))
        try TerrainManifestAsset(meshPrototypes: [.init(id: 1, assetPath: "plant.vox")], meshDocumentFileName: "ground.atmesh")
            .encodedData().write(to: manifest)
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        let owner = app.main.spawn("Terrain") { Transform(); Terrain3DSource(source: manifest.path, generatesCollision: false); }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            if owner.components[Terrain3DSourceStatus.self]?.isReady == true { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        let batches = owner.children.compactMap { $0.components[Mesh3DInstancesComponent.self] }
        #expect(Set(batches.flatMap(\.instances).map(\.id)) == Set(placements.map(\.id)))
        #expect(batches.count == 2)
        #expect(batches.allSatisfy { $0.instances.count == 1 })
        if let first = batches.first?.mesh.models.first?.parts.first?.vertexBuffer {
            #expect(batches.allSatisfy { $0.mesh.models.first?.parts.first?.vertexBuffer === first })
        }
    }
}
