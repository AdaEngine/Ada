@_spi(Internal) @testable import AdaApp
import AdaEngine
@testable import AdaScene
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("An explicit edit cannot replace an unloaded declared region's existing placements and heights")
    func placementEditsRejectUnknownDeclaredBaseline() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try terrainGLTFDocument(normals: 3).write(to: directory.appendingPathComponent("rock.gltf"))
        let first = try TerrainRegionInstance(id: 1, prototypeID: 17, localPosition: [10, 0, 10], flags: [])
        let existing = try TerrainRegionInstance(id: 8, prototypeID: 17, localPosition: [10, 3, 10], flags: [])
        let proposed = try TerrainRegionInstance(id: 9, prototypeID: 17, localPosition: [12, 0, 10], flags: [])
        var samples = Array(repeating: Float(0), count: 4_096)
        samples[650] = 3
        let hidden = TerrainRegionAsset(x: 4, z: 0, tiles: [.init(x: 0, z: 0)], pages: [.init(x: 0, z: 0, samples: samples)], instances: [existing])
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions(
            [
                .init(x: 0, z: 0, tiles: [.init(x: 0, z: 0)], pages: [], instances: [first]), hidden,
            ],
            manifest: .init(meshPrototypes: [.init(id: 17, assetPath: "rock.gltf")]),
            at: file.path
        )
        let app = try await makeApp()
        let owner = app.main.spawn("Terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: 5)
        }
        _ = app.main.spawn("Camera") {
            Transform(position: [10, 20, 10]); Camera()
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        #expect(storage.regionCoordinates == [.init(x: 0, z: 0)])
        owner.components[Terrain3DEdit.self] = .init(storage: storage, instances: [.init(coordinate: .init(x: 16, z: 0), previous: [], instances: [proposed])])
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .failed)
        #expect(storage.regionCoordinates == [.init(x: 0, z: 0)])
        owner.components[Terrain3DSave.self] = .init(storage: storage)
        await finishSave(app, owner: owner)
        #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        let manifest = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        let ref = try #require(manifest.heightRegions.first { $0.x == 4 })
        let saved = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: directory.appendingPathComponent(ref.fileName).path)
        #expect(saved.instances == hidden.instances)
        #expect(saved.pages == hidden.pages)
        #expect(saved.tiles == hidden.tiles)
    }

    @Test("A one-sample sculpt with 100000 unchanged decorative placements exports no unrelated placement rows")
    func localSculptAvoidsUnrelatedPlacementExports() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try terrainGLTFDocument(normals: 3).write(to: directory.appendingPathComponent("rock.gltf"))
        var regions: [TerrainRegionAsset] = []
        for region in 0..<2 {
            let records = try (0..<50_000).map { index in
                try TerrainRegionInstance(id: UInt64(region * 50_000 + index), prototypeID: 17, localPosition: [Float(index % 256) + 0.25, 0, Float(index / 256) + 0.25], flags: [])
            }
            regions.append(.init(x: Int32(region), z: 0, tiles: [.init(x: 0, z: 0)], pages: [], instances: records))
        }
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions(regions, manifest: .init(meshPrototypes: [.init(id: 17, assetPath: "rock.gltf")]), at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 2, streamingRadius: 384)
        }
        let camera = app.main.spawn("Camera") {
            Transform(position: [255, 30, 128]); Camera()
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let identities = try #require(owner.components[TerrainSourceState.self]).instanceCells.mapValues(\.prepared.id)
        _ = storage.takeExportedInstanceRecordCount()
        owner.components[Terrain3DEdit.self] = .init(storage: storage, updates: [.init(point: .init(x: 10, z: 10), height: 4)])
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
        #expect(storage.takeExportedInstanceRecordCount() == 0)
        #expect(owner.components[TerrainSourceState.self]?.instanceCells.mapValues(\.prepared.id) == identities)
        camera.components[Transform.self] = Transform(position: [256, 30, 128])
        await settle(app)
        #expect(storage.takeExportedInstanceRecordCount() == 0)
        #expect(owner.components[TerrainSourceState.self]?.instanceCells.mapValues(\.prepared.id) == identities)
        #expect(owner.components[TerrainSourceState.self]?.groupedInstanceRecordCount == 0)
    }
}
