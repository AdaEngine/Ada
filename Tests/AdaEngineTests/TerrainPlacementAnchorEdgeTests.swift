@_spi(Internal) @testable import AdaApp
import AdaEngine
@testable import AdaScene
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Sculpting a shared region edge reprojects valid halo anchors without promoting hidden draws or deleting saved records")
    func sculptPreservesNormalOnlyPlacementAnchors() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try terrainGLTFDocument(normals: 3).write(to: directory.appendingPathComponent("rock.gltf"))
        let anchor = try TerrainRegionInstance(id: 8, prototypeID: 17, localPosition: [0.5, 0, 10], flags: [.anchored])
        let regions = [
            TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 3, z: 0)], pages: []),
            TerrainRegionAsset(x: 1, z: 0, tiles: [.init(x: 0, z: 0)], pages: [], instances: [anchor]),
        ]
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions(regions, manifest: .init(meshPrototypes: [.init(id: 17, assetPath: "rock.gltf")]), at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: 5)
        }
        _ = app.main.spawn("Camera") {
            Transform(position: [240, 20, 10]); Camera()
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        #expect(storage.tileCoordinates == [.init(x: 3, z: 0)])
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, updates: [.init(point: .init(x: 256, z: 10), height: 4)])
        await settle(app)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.phase == .applied)
        #expect(storage.tileCoordinates == [.init(x: 3, z: 0)])
        let moved = try #require(try storage.regionAsset(at: .init(x: 1, z: 0))?.instances.first)
        #expect(moved.id == anchor.id && abs(moved.localPosition.y - 2) < 0.0001)
        #expect(owner.children.allSatisfy { $0.components[Mesh3DInstancesComponent.self] == nil })
        owner.components[Terrain3DSave.self] = .init(storage: storage)
        await finishSave(app, owner: owner)
        #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        let manifest = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        let ref = try #require(manifest.heightRegions.first { $0.x == 1 })
        let saved = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: directory.appendingPathComponent(ref.fileName).path)
        #expect(saved.instances == [moved])
        #expect(saved.tiles == regions[1].tiles)
    }

    @Test("Many small slope edits keep anchored orientation aligned instead of discarding subthreshold rotations")
    func gradualSculptKeepsAnchorOrientation() throws {
        let anchor = try TerrainRegionInstance(id: 9, prototypeID: 17, localPosition: [10, 0, 10], flags: [.anchored, .alignToNormal])
        let storage = try TerrainHeightStorage(regions: [.init(x: 0, z: 0, tiles: [.init(x: 0, z: 0)], pages: [], instances: [anchor])])
        for step in 1...1_000 {
            let slope = tan(Float(step) * 0.0003)
            let revision = storage.revision
            let staged = try storage.stagedHeights(
                [
                    .init(point: .init(x: 9, z: 10), height: -slope), .init(point: .init(x: 11, z: 10), height: slope),
                ],
                expectedRevision: revision
            )
            _ = try staged.storage.reprojectAnchors(after: staged.delta.changes)
            try storage.commitResidency(staged.storage, expectedRevision: revision)
        }
        let moved = try #require(try storage.regionAsset(at: .init(x: 0, z: 0))?.instances.first)
        let expected = Vector3(-tan(Float(0.3)), 1, 0).normalized
        #expect(moved.anchorNormal.dot(expected) > 0.9999)
        #expect(Transform3D(translation: .zero, rotation: moved.rotation, scale: .one).y.xyz.dot(expected) > 0.9999)
    }
}
