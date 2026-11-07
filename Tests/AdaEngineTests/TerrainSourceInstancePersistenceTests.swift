@_spi(Internal) @testable import AdaApp
import AdaEngine
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Height edits, hidden residency and runtime saves preserve existing placement records")
    func heightSourcePreservesInstancesAcrossSaveAndStreaming() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try TerrainRegionInstance(id: 70, prototypeID: 0, localPosition: [10, 1, 10], flags: [])
        let first = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0)], pages: [], instances: [record])
        let distant = TerrainRegionAsset(x: 4, z: 0, tiles: [.init(x: 0, z: 0)], pages: [])
        try terrainGLTFDocument(normals: 3).write(to: directory.appendingPathComponent("rock.gltf"))
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions([first, distant], manifest: .init(meshPrototypes: [.init(id: 0, assetPath: "rock.gltf")]), at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumResidentHeightBytes: 32_768, maximumLOD: 0, streamingRadius: 20)
        }
        let camera = app.main.spawn("Camera") {
            Transform(position: [10, 20, 10]); Camera()
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        #expect(try storage.regionAsset(at: .init(x: 0, z: 0))?.instances == [record])
        try storage.setHeight(6, at: .init(x: 10, z: 10))
        await settle(app)
        camera.components[Transform.self] = Transform(position: [1_034, 20, 10])
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(try storage.regionAsset(at: .init(x: 0, z: 0))?.instances == [record])
        owner.components[Terrain3DSave.self] = .init(storage: storage)
        await finishSave(app, owner: owner)
        try #require(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        let manifest = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        let ref = try #require(manifest.heightRegions.first { $0.x == 0 })
        let payload = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: directory.appendingPathComponent(ref.fileName).path)
        #expect(payload.instances == [record])
        #expect(payload.tiles == first.tiles && payload.pages.first?.samples[650] == 6)
        camera.components[Transform.self] = Transform(position: [10, 20, 10])
        await settle(app)
        #expect(try storage.regionAsset(at: .init(x: 0, z: 0))?.instances == [record])
    }

    @Test("Runtime saves persist removal of a placement-only region instead of resurrecting its records")
    func removesPlacementOnlySourceResource() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try TerrainRegionInstance(id: 71, prototypeID: 0, localPosition: [10, 1, 10], flags: [])
        let region = TerrainRegionAsset(x: 0, z: 0, tiles: [], pages: [], instances: [record])
        try terrainGLTFDocument(normals: 3).write(to: directory.appendingPathComponent("rock.gltf"))
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions([region], manifest: .init(meshPrototypes: [.init(id: 0, assetPath: "rock.gltf")]), at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        #expect(storage.residentInstanceBytes > 0)
        #expect(try storage.removeRegion(at: .init(x: 0, z: 0)))
        await settle(app)
        owner.components[Terrain3DSave.self] = .init(storage: storage)
        await finishSave(app, owner: owner)
        try #require(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        let manifest = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        #expect(manifest.heightRegions.isEmpty)
        #expect(storage.resourceCoordinates.isEmpty)
    }
}
