@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Camera distance changes rendered tile detail while collision keeps a narrow height feature and camera motion within a band retains buffers")
    func cameraLODAndCanonicalCollision() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var terrain = Terrain3D(resolution: 129, size: 128)
        terrain.heights[10 * 129 + 10] = 10
        let file = try await save(terrain, in: directory)
        let app = try await makeApp(physics: true)
        let owner = app.main.spawn("Terrain asset") {
            Transform(); Terrain3DSource(source: file.path, streamingRadius: nil)
        }
        let rig = app.main.spawn("Camera rig") { Transform(position: [10_000, 0, 0]) }
        let camera = app.main.spawn("Camera") {
            Transform(); Camera()
        }
        rig.addChild(camera)
        func counts() throws -> [Int] {
            try owner.children.compactMap { child in
                guard child.components[TerrainTile3DComponent.self] != nil else {
                    return nil
                }
                return try #require(child.components[Mesh3DComponent.self]?.mesh.models.first?.parts.first?.indexCount)
            }.sorted()
        }
        await settle(app)
        #expect(try counts() == Array(repeating: 6, count: 4))
        await app.main.runScheduler(.physicsSync)
        let physics = try #require(app.main.physicsWorld3D)
        let fraction = physics.sphereCastFraction(from: [-54, 20, -54], to: [-54, -20, -54], radius: 0.05)
        #expect(fraction > 0.23 && fraction < 0.26)
        #expect(owner.components[Terrain3DSourceSurface.self]?.storage.height(atSample: .init(x: 10, z: 10)) == 10)
        rig.components[Transform.self] = Transform()
        await settle(app)
        #expect(try counts() == Array(repeating: 64 * 64 * 6, count: 4))
        let detailed = try buffers(owner)
        await app.main.runScheduler(.physicsSync)
        #expect(physics.sphereCastFraction(from: [-54, 20, -54], to: [-54, -20, -54], radius: 0.05) == fraction)
        rig.components[Transform.self] = Transform(position: [0.1, 0, 0])
        await settle(app)
        #expect(try buffers(owner) == detailed)
        rig.components[Transform.self] = Transform(position: [10_000, 0, 0])
        await settle(app)
        #expect(try counts() == Array(repeating: 6, count: 4))
        var inactive = Camera()
        inactive.isActive = false
        camera.components[Camera.self] = inactive
        await settle(app)
        #expect(try counts() == Array(repeating: 64 * 64 * 6, count: 4))
    }

    @Test("A camera does not implicitly retry an initially missing source after its file appears")
    func failedInitialLoadWithCamera() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("world.aterrain")
        let app = try await makeApp()
        var source = Terrain3DSource(source: file.path, generatesCollision: false, streamingRadius: nil)
        let owner = app.main.spawn("Terrain asset") {
            Transform(); source
        }
        app.main.spawn("Camera") {
            Transform(position: [10_000, 0, 0]); Camera()
        }
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == false)
        #expect(owner.children.isEmpty)
        _ = try await save(Terrain3D(resolution: 65, size: 64), in: directory)
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == false)
        #expect(owner.components[Terrain3DSourceSurface.self] == nil)
        #expect(owner.children.isEmpty)
        source.reloadGeneration += 1
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(owner.children.compactMap { $0.components[Mesh3DComponent.self]?.mesh.models.first?.parts.first?.indexCount } == [6])
    }

    @Test("Camera residency admits nearby regions from a larger manifest and releases distant geometry without changing the storage identity")
    func streamsRegionsAroundCamera() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authored = try TerrainHeightStorage()
        try authored.allocateRegion(at: .init(x: 0, z: 0))
        try authored.allocateRegion(at: .init(x: 20, z: 0))
        var resources: [TerrainRegionAsset] = []
        for coordinate in authored.resourceCoordinates { if let region = try authored.regionAsset(at: coordinate) { resources.append(region) } }
        let file = directory.appendingPathComponent("world.aterrain")
        _ = try await AssetsManager.saveTerrainRegions(resources, manifest: TerrainManifestAsset(), at: file.path)
        let app = try await makeApp()
        let source = Terrain3DSource(source: file.path, generatesCollision: false, maximumResidentRegions: 1, streamingRadius: 128)
        let owner = app.main.spawn("Terrain asset") {
            Transform(); source
        }
        let camera = app.main.spawn("Camera") {
            Transform(position: [128, 0, 128]); Camera()
        }
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(try buffers(owner).count == 16)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        #expect(storage.regionCoordinates == [.init(x: 0, z: 0)])
        camera.components[Transform.self] = Transform(position: [20 * 256 + 128, 0, 128])
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(try buffers(owner).count == 16)
        #expect(owner.children.count == 16)
        #expect(owner.components[Terrain3DSourceSurface.self]?.storage === storage)
        #expect(storage.regionCoordinates == [.init(x: 20, z: 0)])
        #expect(storage.height(at: [128, 128]) == nil)
        #expect(storage.height(at: [20 * 256 + 128, 128]) == 0)
    }

    @Test("Dirty data survives residency admission failures and budget changes, and restores when its region becomes visible again")
    func dirtyResidencyAndBudgetChanges() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authored = try TerrainHeightStorage()
        try authored.allocateRegion(at: .init(x: 0, z: 0))
        try authored.allocateRegion(at: .init(x: 20, z: 0))
        var resources: [TerrainRegionAsset] = []
        for coordinate in authored.resourceCoordinates { if let region = try authored.regionAsset(at: coordinate) { resources.append(region) } }
        let file = directory.appendingPathComponent("world.aterrain")
        _ = try await AssetsManager.saveTerrainRegions(resources, manifest: TerrainManifestAsset(), at: file.path)
        let app = try await makeApp()
        var source = Terrain3DSource(source: file.path, generatesCollision: false, maximumResidentRegions: 1, streamingRadius: 128)
        let owner = app.main.spawn("Terrain asset") {
            Transform(); source
        }
        let camera = app.main.spawn("Camera") {
            Transform(position: [128, 0, 128]); Camera()
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        try storage.setHeight(3, at: .init(x: 10, z: 10))
        await settle(app)
        let edited = try buffers(owner)
        camera.components[Transform.self] = Transform(position: [20 * 256 + 128, 0, 128])
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == false)
        #expect(try buffers(owner) == edited)
        #expect(storage.regionCoordinates == [.init(x: 0, z: 0)])
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == 3)
        source.maximumResidentRegions = 2
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(owner.components[Terrain3DSourceSurface.self]?.storage === storage)
        #expect(storage.regionCoordinates == [.init(x: 20, z: 0)])
        camera.components[Transform.self] = Transform(position: [128, 0, 128])
        await settle(app)
        #expect(owner.components[Terrain3DSourceSurface.self]?.storage.height(atSample: .init(x: 10, z: 10)) == 3)
        source.maximumResidentHeightBytes = 32 * 1_024 * 1_024
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.components[Terrain3DSourceSurface.self]?.storage === storage)
        #expect(storage.memoryBudgetBytes == 32 * 1_024 * 1_024)
        #expect(owner.components[Terrain3DSourceSurface.self]?.storage.height(atSample: .init(x: 10, z: 10)) == 3)
        let beforeFailure = try buffers(owner)
        source.maximumResidentHeightBytes = 0
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == false)
        #expect(try buffers(owner) == beforeFailure)
        #expect(storage.memoryBudgetBytes == 32 * 1_024 * 1_024)
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == 3)
        source.maximumResidentHeightBytes = 32 * 1_024 * 1_024
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
    }
}
