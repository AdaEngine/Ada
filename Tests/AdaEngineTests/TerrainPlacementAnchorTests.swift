@_spi(Internal) @testable import AdaApp
import AdaEngine
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Sculpting reprojects only nearby anchored placements and normal alignment in the same published edit")
    func sculptReprojectsPlacementAnchors() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try terrainGLTFDocument(normals: 3).write(to: directory.appendingPathComponent("rock.gltf"))
        let anchored = try TerrainRegionInstance(
            id: 1,
            prototypeID: 17,
            localPosition: [10, 1, 10],
            rotation: Quat(axis: [0, 1, 0], angle: .pi / 2),
            flags: [.anchored, .alignToNormal],
            anchorOffset: 1
        )
        let free = try TerrainRegionInstance(id: 2, prototypeID: 17, localPosition: [10, 8, 10], flags: [])
        let distant = try TerrainRegionInstance(id: 3, prototypeID: 17, localPosition: [70, 6, 10], flags: [.anchored])
        let region = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0)], pages: [], instances: [anchored, free, distant])
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions([region], manifest: .init(meshPrototypes: [.init(id: 17, assetPath: "rock.gltf")]), at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let edits: [TerrainHeightUpdate] = [
            .init(point: .init(x: 10, z: 10), height: 4), .init(point: .init(x: 11, z: 10), height: 6),
            .init(point: .init(x: 9, z: 10), height: 2), .init(point: .init(x: 10, z: 11), height: 4), .init(point: .init(x: 10, z: 9), height: 4),
        ]
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, updates: edits)
        await settle(app)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.phase == .applied)
        let delta = try #require(owner.components[Terrain3DHeightEditStatus.self]?.delta)
        let saved = try #require(try storage.regionAsset(at: .init(x: 0, z: 0)))
        let moved = try #require(saved.instances.first { $0.id == 1 })
        #expect(abs(moved.localPosition.y - 5) < 0.0001)
        let normal = Vector3(-2, 1, 0).normalized
        #expect(moved.anchorNormal.dot(normal) > 0.9999)
        #expect(Transform3D(translation: .zero, rotation: moved.rotation, scale: .one).y.xyz.dot(normal) > 0.9999)
        #expect(saved.instances.first { $0.id == 2 } == free)
        #expect(saved.instances.first { $0.id == 3 } == distant)
        let draw = try #require(owner.children.compactMap { $0.components[Mesh3DInstancesComponent.self] }.flatMap(\.instances).first { $0.id == 1 })
        #expect(abs(draw.transform.origin.y - 5) < 0.0001)
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, updates: delta.reversedUpdates)
        await settle(app)
        let restored = try #require(try storage.regionAsset(at: .init(x: 0, z: 0))?.instances.first { $0.id == 1 })
        #expect(abs(restored.localPosition.y - 1) < 0.0001)
        #expect(abs(restored.rotation.dot(anchored.rotation)) > 0.9999)
        #expect(restored.anchorNormal.dot([0, 1, 0]) > 0.9999)
        owner.components[Terrain3DSave.self] = .init(storage: storage)
        await finishSave(app, owner: owner)
        #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        let manifest = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        let ref = try #require(manifest.heightRegions.first)
        let roundTrip = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: directory.appendingPathComponent(ref.fileName).path)
        #expect(roundTrip.instances == [restored, free, distant])
    }
}
