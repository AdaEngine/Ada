@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

@MainActor
@Suite("Terrain asset runtime", .serialized)
struct TerrainSourceRuntimeTests {
    func makeApp(physics: Bool = false, world: World? = nil) async throws -> AppWorlds {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let app = AppWorlds(main: world ?? World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        if physics { app.addPlugin(Physics3DPlugin()) }
        try await app.build()
        return app
    }

    func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("AdaTerrainSource-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try #require(directory.deletingLastPathComponent() == root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func save(_ terrain: Terrain3D, in directory: URL) async throws -> URL {
        let storage = try TerrainHeightStorage(importing: terrain)
        return try await save(storage, in: directory)
    }

    func save(_ storage: TerrainHeightStorage, in directory: URL) async throws -> URL {
        var resources: [TerrainRegionAsset] = []
        for coordinate in storage.resourceCoordinates { if let asset = try storage.regionAsset(at: coordinate) { resources.append(asset) } }
        let file = directory.appendingPathComponent("world.aterrain")
        let manifest = TerrainManifestAsset(spacing: storage.spacing, originX: storage.origin.x, originZ: storage.origin.y)
        _ = try await AssetsManager.saveTerrainRegions(resources, manifest: manifest, at: file.path)
        return file
    }

    func settle(_ app: AppWorlds) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        var quietFrames = 0
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            let pending = app.main.getEntities().contains { entity in
                guard entity.components[Terrain3DSource.self] != nil else {
                    return false
                }
                guard let status = entity.components[Terrain3DSourceStatus.self] else {
                    return true
                }
                return !status.isReady && status.error == nil
            }
            quietFrames = pending ? 0 : quietFrames + 1
            if quietFrames >= 3 {
                return
            }
            do { try await Task.sleep(for: .milliseconds(1)) } catch { return }
        }
        Issue.record("Terrain did not settle before its bounded deadline")
    }

    func buffers(_ owner: Entity) throws -> [TerrainTileCoordinate: ObjectIdentifier] {
        var result: [TerrainTileCoordinate: ObjectIdentifier] = [:]
        for child in owner.children {
            guard let tile = child.components[TerrainTile3DComponent.self] else { continue }
            let mesh = try #require(child.components[Mesh3DComponent.self]?.mesh)
            let part = try #require(mesh.models.first?.parts.first)
            result[tile.coordinate] = ObjectIdentifier(part.vertexBuffer)
        }
        return result
    }

    @Test("A manifest renders migrated partial regions; local data edits preserve distant buffers, shared material and cleanup")
    func loadsAndUpdatesAssetTiles() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await save(Terrain3D(resolution: 129, size: 128), in: directory)
        let app = try await makeApp()
        var source = Terrain3DSource(source: file.path, generatesCollision: false)
        let owner = app.main.spawn("Terrain asset") {
            Transform(); source
        }
        await settle(app)
        let initial = try buffers(owner)
        #expect(initial.count == 4)
        let surface = try #require(owner.components[Terrain3DSourceSurface.self])
        #expect(surface.storage.tileCoordinates.count == 4)
        try surface.storage.setHeight(3, at: .init(x: 10, z: 10))
        await settle(app)
        let edited = try buffers(owner)
        #expect(edited[.init(x: 0, z: 0)] != initial[.init(x: 0, z: 0)])
        for coordinate in initial.keys where coordinate != .init(x: 0, z: 0) { #expect(edited[coordinate] == initial[coordinate]) }
        source.color = [0.2, 0.3, 0.7, 1]
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(try buffers(owner) == edited)
        let materials = owner.children.compactMap { $0.components[Mesh3DComponent.self]?.materials.first as? PBRMaterial }
        #expect(materials.count == 4 && Set(materials.map(ObjectIdentifier.init)).count == 1)
        #expect(materials.allSatisfy { $0.baseColorFactor == source.color })
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        owner.components.remove(Terrain3DSource.self)
        await settle(app)
        #expect(owner.children.isEmpty)
        #expect(owner.components[Terrain3DSourceSurface.self] == nil)
    }

    @Test("Asset colliders include reflected parent transforms and a failed replacement preserves the previous valid generation")
    func collisionAndFailedReplacement() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var terrain = Terrain3D(resolution: 65, size: 64)
        terrain.heights = Array(repeating: 2, count: 65 * 65)
        let file = try await save(terrain, in: directory)
        let app = try await makeApp(physics: true)
        let parent = app.main.spawn("Environment") { Transform(position: [0, 3, 0]) }
        var source = Terrain3DSource(source: file.path)
        let owner = app.main.spawn("Terrain asset") {
            Transform(scale: [-1, 1, 1]); source
        }
        parent.addChild(owner)
        await settle(app)
        await app.main.runScheduler(.physicsSync)
        let physics = try #require(app.main.physicsWorld3D)
        let fraction = physics.sphereCastFraction(from: [0, 10, 0], to: [0, -10, 0], radius: 0.25)
        #expect(fraction > 0.23 && fraction < 0.25)
        let original = try buffers(owner)
        #expect(original.count == 1)
        source.source = directory.appendingPathComponent("missing.aterrain").path
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(try buffers(owner) == original)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == false)
        #expect(owner.components[Terrain3DSourceStatus.self]?.error != nil)
        #expect(physics.sphereCastFraction(from: [0, 10, 0], to: [0, -10, 0], radius: 0.25) == fraction)
        source.source = file.path
        source.generatesCollision = false
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        await app.main.runScheduler(.physicsSync)
        #expect(physics.sphereCastFraction(from: [0, 10, 0], to: [0, -10, 0], radius: 0.25) == 1)
    }

    @Test("A failed replacement keeps the resident surface responsive to parent movement and can recover without rebuilding visible meshes")
    func movesWhileReplacementFails() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await save(Terrain3D(resolution: 65, size: 64), in: directory)
        let app = try await makeApp(physics: true)
        let parent = app.main.spawn("Environment") { Transform() }
        var source = Terrain3DSource(source: file.path)
        let owner = app.main.spawn("Terrain asset") {
            Transform(); source
        }
        parent.addChild(owner)
        await settle(app)
        let original = try buffers(owner)
        source.source = directory.appendingPathComponent("missing.aterrain").path
        owner.components[Terrain3DSource.self] = source
        parent.components[Transform.self] = Transform(position: [0, 3, 0])
        await settle(app)
        await app.main.runScheduler(.physicsSync)
        let physics = try #require(app.main.physicsWorld3D)
        let fraction = physics.sphereCastFraction(from: [0, 10, 0], to: [0, -10, 0], radius: 0.25)
        #expect(fraction > 0.33 && fraction < 0.35)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == false)
        source.source = file.path
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        await app.main.runScheduler(.physicsSync)
        #expect(try buffers(owner) == original)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(physics.sphereCastFraction(from: [0, 10, 0], to: [0, -10, 0], radius: 0.25) > 0.33)
        #expect(physics.sphereCastFraction(from: [0, 10, 0], to: [0, -10, 0], radius: 0.25) < 0.35)
    }

    @Test("Local edits after a failed replacement update the resident generation; an explicit retry loads the repaired file")
    func editsResidentUntilExplicitRetry() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await save(Terrain3D(resolution: 65, size: 64), in: directory)
        let app = try await makeApp()
        var source = Terrain3DSource(source: file.path, generatesCollision: false)
        let owner = app.main.spawn("Terrain asset") {
            Transform(); source
        }
        await settle(app)
        let resident = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let initial = try buffers(owner)
        let replacement = directory.appendingPathComponent("Replacement", isDirectory: true)
        source.source = replacement.appendingPathComponent("world.aterrain").path
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == false)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        var repaired = Terrain3D(resolution: 65, size: 64)
        repaired.heights = Array(repeating: 9, count: 65 * 65)
        _ = try await save(repaired, in: replacement)
        try resident.setHeight(3, at: .init(x: 10, z: 10))
        await settle(app)
        #expect(owner.components[Terrain3DSourceSurface.self]?.storage === resident)
        #expect(try buffers(owner) != initial)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == false)
        #expect(resident.height(atSample: .init(x: 10, z: 10)) == 3)
        source.reloadGeneration += 1
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(owner.components[Terrain3DSourceSurface.self]?.storage.height(atSample: .init(x: 10, z: 10)) == 9)
    }

    @Test("Height/mesh admission fails without publishing partial children and emptying the source clears a loaded generation")
    func budgetsAndClear() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var terrain = Terrain3D(resolution: 65, size: 64)
        terrain.heights = Array(repeating: 2, count: 65 * 65)
        let file = try await save(terrain, in: directory)
        let app = try await makeApp()
        var source = Terrain3DSource(source: file.path, generatesCollision: false, maximumResidentHeightBytes: 0)
        let owner = app.main.spawn("Terrain asset") {
            Transform(); source
        }
        await settle(app)
        #expect(owner.children.isEmpty)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == false)
        #expect(owner.components[Terrain3DSourceSurface.self] == nil)
        source.maximumResidentHeightBytes = 64 * 1_024 * 1_024
        source.maximumMeshBytes = 0
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.children.isEmpty)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == false)
        #expect(owner.components[Terrain3DSourceSurface.self] == nil)
        source.maximumMeshBytes = 128 * 1_024 * 1_024
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(try buffers(owner).count == 1)
        source.source = ""
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.children.isEmpty)
        #expect(owner.components[Terrain3DSourceSurface.self] == nil)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(owner.components[Terrain3DSourceStatus.self]?.tileCount == 0)
    }
}
