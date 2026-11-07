@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    func finishSave(_ app: AppWorlds, owner: Entity) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            if let status = owner.components[Terrain3DSaveStatus.self], status.phase != .pending {
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func largeSaveFixture(in directory: URL) async throws -> URL {
        let storage = try TerrainHeightStorage()
        for x in [0, 4, 8] {
            try storage.allocateRegion(at: .init(x: x, z: 0))
            try storage.setHeight(1, at: .init(x: x * 256 + 10, z: 10))
        }
        return try await save(storage, in: directory)
    }

    @Test("Runtime saves retain unloaded regions and release saved dirty pins before revisiting the new disk generation")
    func savesAndAdoptsStreamedGeneration() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await largeSaveFixture(in: directory)
        let initial = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumResidentHeightBytes: 16_384, maximumLOD: 0, streamingRadius: 20)
        }
        let camera = app.main.spawn("Camera") {
            Transform(position: [10, 20, 10]); Camera()
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        try storage.setHeight(7, at: .init(x: 10, z: 10))
        await settle(app)
        let before = try buffers(owner)
        owner.components[Terrain3DSave.self] = .init(storage: storage, maximumStagedBytes: 20_000)
        await finishSave(app, owner: owner)
        #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        try #require(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        #expect(owner.components[Terrain3DSave.self] == nil)
        #expect(owner.components[Terrain3DSourceSurface.self]?.storage === storage)
        #expect(try buffers(owner) == before)
        let saved = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        #expect(saved.heightRegions.count == 3)
        #expect(saved.heightRegions.filter { $0.x != 0 } == initial.heightRegions.filter { $0.x != 0 })
        camera.components[Transform.self] = Transform(position: [1_034, 20, 10])
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == nil)
        #expect(storage.height(atSample: .init(x: 1_034, z: 10)) == 1)
        try storage.setHeight(9, at: .init(x: 1_034, z: 10))
        await settle(app)
        owner.components[Terrain3DSave.self] = .init(storage: storage, maximumStagedBytes: 20_000)
        await finishSave(app, owner: owner)
        #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        camera.components[Transform.self] = Transform(position: [10, 20, 10])
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == 7)
    }

    @Test("Saving hidden dirty regions restores their authored physical tile layout in the persisted payload")
    func savesHiddenDirtyRegion() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await largeSaveFixture(in: directory)
        let app = try await makeApp()
        let owner = app.main.spawn("Terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumResidentHeightBytes: 32_768, maximumLOD: 0, streamingRadius: 20)
        }
        let camera = app.main.spawn("Camera") {
            Transform(position: [10, 20, 10]); Camera()
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        try storage.setHeight(6, at: .init(x: 10, z: 10))
        await settle(app)
        camera.components[Transform.self] = Transform(position: [1_034, 20, 10])
        await settle(app)
        #expect(try storage.regionAsset(at: .init(x: 0, z: 0))?.tiles.isEmpty == true)
        owner.components[Terrain3DSave.self] = .init(storage: storage)
        await finishSave(app, owner: owner)
        #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        try #require(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        let manifest = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        let ref = try #require(manifest.heightRegions.first { $0.x == 0 })
        let payload = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: directory.appendingPathComponent(ref.fileName).path)
        #expect(payload.tiles.count == 16)
        #expect(payload.pages.first?.samples[10 * 64 + 10] == 6)
        camera.components[Transform.self] = Transform(position: [10, 20, 10])
        await settle(app)
        #expect(storage.tileCoordinates.count == 16)
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == 6)
    }

    @Test("A stale disk generation fails a runtime save while keeping local edits and published geometry available")
    func failedRuntimeSavePreservesLocalEdit() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await save(Terrain3D(resolution: 65, size: 64), in: directory)
        let app = try await makeApp()
        let owner = app.main.spawn("Terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        try storage.setHeight(4, at: .init(x: 10, z: 10))
        await settle(app)
        let before = try buffers(owner)
        let original = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        _ = try await AssetsManager.saveTerrainRegions([], manifest: original, at: file.path)
        let external = try Data(contentsOf: file)
        owner.components[Terrain3DSave.self] = .init(storage: storage)
        await finishSave(app, owner: owner)
        #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .failed)
        #expect(owner.components[Terrain3DSaveStatus.self]?.error != nil)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == 4)
        #expect(try buffers(owner) == before)
        #expect(try Data(contentsOf: file) == external)
    }
}
