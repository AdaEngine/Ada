@_spi(Internal) @testable import AdaApp
import AdaEngine
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    private func placementHistoryFixture(in directory: URL, records: [TerrainRegionInstance]) async throws -> (AppWorlds, Entity, TerrainHeightStorage) {
        try terrainGLTFDocument(normals: 3).write(to: directory.appendingPathComponent("rock.gltf"))
        let file = directory.appendingPathComponent("world.aterrain")
        let region = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0)], pages: [], instances: records)
        try await AssetsManager.saveTerrainRegions([region], manifest: .init(meshPrototypes: [.init(id: 17, assetPath: "rock.gltf")]), at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0)
        }
        await settle(app)
        return (app, owner, try #require(owner.components[Terrain3DSourceSurface.self]?.storage))
    }

    @Test("Combined terrain Undo and Redo restore exact compact placement channels across repeated sculpt gestures")
    func placementHistoryRestoresExactRows() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try TerrainRegionInstance(
            id: 1,
            prototypeID: 17,
            localPosition: [10, 1, 10],
            rotation: .euler([0.2, 0.42, -0.1]),
            tint: [0.12, 0.34, 0.56, 0.78],
            seed: 77,
            flags: [.anchored, .alignToNormal],
            anchorOffset: 1
        )
        let (app, owner, storage) = try await placementHistoryFixture(in: directory, records: [original])
        let before = try #require(try storage.regionAsset(at: .init(x: 0, z: 0))).encodedData()
        owner.components[Terrain3DEdit.self] = .init(storage: storage, updates: [.init(point: .init(x: 11, z: 10), height: 4)])
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
        var delta = try #require(owner.components[Terrain3DEditStatus.self]?.delta)
        #expect(delta.instanceChanges.count == 1)
        let after = try #require(try storage.regionAsset(at: .init(x: 0, z: 0))).encodedData()
        #expect(before != after)
        for _ in 0..<5 {
            owner.components[Terrain3DEdit.self] = .init(storage: storage, undoing: delta)
            await settle(app)
            #expect(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
            let restored = try #require(try storage.regionAsset(at: .init(x: 0, z: 0))).encodedData()
            #expect(restored == before)
            let undoDelta = try #require(owner.components[Terrain3DEditStatus.self]?.delta)
            owner.components[Terrain3DEdit.self] = .init(storage: storage, undoing: undoDelta)
            await settle(app)
            #expect(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
            let redone = try #require(try storage.regionAsset(at: .init(x: 0, z: 0))).encodedData()
            #expect(redone == after)
            delta = try #require(owner.components[Terrain3DEditStatus.self]?.delta)
        }
    }

    @Test("Explicit placement edits publish, save and undo added records as one terrain revision")
    func placementEditsPublishAndUndo() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try TerrainRegionInstance(id: 1, prototypeID: 17, localPosition: [10, 0, 10], flags: [])
        let second = try TerrainRegionInstance(id: 2, prototypeID: 17, localPosition: [12, 0, 10], flags: [])
        let (app, owner, storage) = try await placementHistoryFixture(in: directory, records: [first])
        let revision = storage.revision
        owner.components[Terrain3DEdit.self] = .init(storage: storage, instances: [.init(coordinate: .init(x: 0, z: 0), previous: [first], instances: [first, second])])
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
        #expect(storage.revision == revision + 1)
        #expect(try storage.regionAsset(at: .init(x: 0, z: 0))?.instances == [first, second])
        #expect(owner.children.compactMap { $0.components[Mesh3DInstancesComponent.self] }.flatMap(\.instances).map(\.id) == [1, 2])
        let delta = try #require(owner.components[Terrain3DEditStatus.self]?.delta)
        owner.components[Terrain3DSave.self] = .init(storage: storage)
        await finishSave(app, owner: owner)
        #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        owner.components[Terrain3DEdit.self] = .init(storage: storage, undoing: delta)
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
        #expect(try storage.regionAsset(at: .init(x: 0, z: 0))?.instances == [first])
        #expect(owner.children.compactMap { $0.components[Mesh3DInstancesComponent.self] }.flatMap(\.instances).map(\.id) == [1])
        owner.components[Terrain3DSave.self] = .init(storage: storage)
        await finishSave(app, owner: owner)
        #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
    }
    @Test("Invalid placement requests fail atomically instead of accepting stale rows, duplicate IDs or wrong cell coordinates")
    func invalidPlacementEditsKeepPublishedRows() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try TerrainRegionInstance(id: 1, prototypeID: 17, localPosition: [10, 0, 10], flags: [])
        let other = try TerrainRegionInstance(id: 2, prototypeID: 17, localPosition: [70, 0, 10], flags: [])
        let (app, owner, storage) = try await placementHistoryFixture(in: directory, records: [first, other])
        let revision = storage.revision
        let invalid: [TerrainInstanceCellChange] = [
            .init(coordinate: .init(x: 0, z: 0), previous: [], instances: [first]),
            .init(coordinate: .init(x: 0, z: 0), previous: [first], instances: [first, first]),
            .init(coordinate: .init(x: 0, z: 0), previous: [first], instances: [first, other]),
            .init(coordinate: .init(x: Int.max, z: 0), previous: [], instances: [first]),
        ]
        for change in invalid {
            owner.components[Terrain3DEdit.self] = .init(storage: storage, instances: [change])
            await settle(app)
            #expect(owner.components[Terrain3DEditStatus.self]?.phase == .failed)
            #expect(owner.components[Terrain3DEditStatus.self]?.error != nil)
            #expect(storage.revision == revision)
            #expect(try storage.regionAsset(at: .init(x: 0, z: 0))?.instances == [first, other])
            #expect(owner.children.compactMap { $0.components[Mesh3DInstancesComponent.self] }.flatMap(\.instances).map(\.id).sorted() == [1, 2])
        }
    }

    @Test("Placement edits admit new hidden dirty regions against source residency limits before publishing")
    func placementEditsRespectDirtyRegionAdmission() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try TerrainRegionInstance(id: 1, prototypeID: 17, localPosition: [10, 0, 10], flags: [])
        let second = try TerrainRegionInstance(id: 2, prototypeID: 17, localPosition: [10, 0, 10], flags: [])
        let (app, owner, storage) = try await placementHistoryFixture(in: directory, records: [first])
        _ = app.main.spawn("Camera") {
            Transform(position: [10, 20, 10]); Camera()
        }
        var source = try #require(owner.components[Terrain3DSource.self])
        source.maximumResidentRegions = 1
        source.streamingRadius = 5
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        let revision = storage.revision
        owner.components[Terrain3DEdit.self] = .init(storage: storage, instances: [.init(coordinate: .init(x: 4, z: 0), previous: [], instances: [second])])
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .failed)
        #expect(owner.components[Terrain3DEditStatus.self]?.error != nil)
        #expect(storage.revision == revision)
        #expect(storage.regionCoordinates == [.init(x: 0, z: 0)])
        #expect(owner.children.compactMap { $0.components[Mesh3DInstancesComponent.self] }.flatMap(\.instances).map(\.id) == [1])
    }
}
