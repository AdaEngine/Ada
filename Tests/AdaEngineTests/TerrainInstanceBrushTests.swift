@_spi(Internal) @testable import AdaApp
import AdaEngine
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    private func instancePaintFixture(in directory: URL, sloped: Bool = false, instances: [TerrainRegionInstance] = []) async throws -> (AppWorlds, Entity, TerrainHeightStorage, URL) {
        try terrainGLTFDocument(normals: 3).write(to: directory.appendingPathComponent("rock.gltf"))
        let samples = (0..<4_096).map { sloped ? Float($0 % 64) : Float(2) }
        let region = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0)], pages: [.init(x: 0, z: 0, samples: samples)], instances: instances)
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions([region], manifest: .init(meshPrototypes: [.init(id: 17, assetPath: "rock.gltf")]), at: file.path)
        let app = try await makeApp()
        let owner = app.main.spawn("Terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
        }
        await settle(app)
        return (app, owner, try #require(owner.components[Terrain3DSourceSurface.self]?.storage), file)
    }

    private func instancePaintSettings() -> TerrainInstanceBrushSettings {
        var settings = TerrainInstanceBrushSettings(prototypeID: 17, radius: 4, density: 2)
        settings.shape = .hardRound
        settings.minimumDistance = 0.75
        settings.seed = 1_234
        settings.heightOffset = 0.25
        settings.tint = [0.25, 0.5, 0.75, 1]
        return settings
    }

    private func instancePaintStroke(_ settings: TerrainInstanceBrushSettings, points: [TerrainBrushPoint]? = nil) -> TerrainInstanceBrushStroke {
        .init(settings: settings, points: points ?? [.init(position: [20, 2, 20], time: 0), .init(position: [20, 2, 20], time: 0.1)])
    }

    @Test("Mesh paint produces shared, spaced, anchored stable records and persists their compact transforms across reload and Undo")
    func meshBrushPaintPersistsAndUndoes() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, owner, originalStorage, file) = try await instancePaintFixture(in: directory)
        let settings = instancePaintSettings()
        let stroke = instancePaintStroke(settings)
        owner.components[Terrain3DEdit.self] = .init(storage: originalStorage, brush: stroke)
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
        let rows = try #require(try originalStorage.regionAsset(at: .init(x: 0, z: 0))).instances
        try #require(!rows.isEmpty)
        #expect(Set(rows.map(\.id)).count == rows.count)
        for (index, row) in rows.enumerated() {
            #expect(row.prototypeID == 17 && row.flags.contains(.anchored) && row.flags.contains(.alignToNormal))
            #expect(abs(row.localPosition.y - 2.25) < 0.0001 && abs(row.anchorOffset - 0.25) < 0.0001)
            #expect(settings.scaleRange.contains(row.scale.x) && row.scale.x == row.scale.y && row.scale.y == row.scale.z)
            #expect(row.anchorNormal.dot([0, 1, 0]) > 0.9999)
            #expect(Transform3D(translation: .zero, rotation: row.rotation, scale: .one).y.xyz.dot([0, 1, 0]) > 0.9999)
            let dx = row.localPosition.x - 20, dz = row.localPosition.z - 20
            #expect(dx * dx + dz * dz < 16.0001)
            for other in rows.dropFirst(index + 1) {
                let x = row.localPosition.x - other.localPosition.x, z = row.localPosition.z - other.localPosition.z
                #expect(x * x + z * z >= settings.minimumDistance * settings.minimumDistance - 0.0001)
            }
        }
        let cells = owner.children.filter { $0.components[Mesh3DInstancesComponent.self] != nil }
        #expect(cells.count == 1)
        #expect(cells.flatMap { $0.components[Mesh3DInstancesComponent.self]?.instances ?? [] }.map(\.id) == rows.map(\.id))
        let delta = try #require(owner.components[Terrain3DEditStatus.self]?.delta)
        let revision = originalStorage.revision
        owner.components[Terrain3DEdit.self] = .init(storage: originalStorage, brush: stroke)
        await settle(app)
        #expect(originalStorage.revision == revision)
        #expect(try originalStorage.regionAsset(at: .init(x: 0, z: 0))?.instances == rows)
        #expect(Set(owner.children.filter { $0.components[Mesh3DInstancesComponent.self] != nil }.map(\.id)) == Set(cells.map(\.id)))
        owner.components[Terrain3DSave.self] = .init(storage: originalStorage)
        await finishSave(app, owner: owner)
        #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        let manifest = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        let ref = try #require(manifest.heightRegions.first)
        let saved = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: directory.appendingPathComponent(ref.fileName).path)
        #expect(saved.instances == rows)
        var source = try #require(owner.components[Terrain3DSource.self])
        source.reloadGeneration &+= 1
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        #expect(try storage.regionAsset(at: .init(x: 0, z: 0))?.instances == rows)
        owner.components[Terrain3DEdit.self] = .init(storage: storage, undoing: delta)
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
        #expect(try storage.regionAsset(at: .init(x: 0, z: 0))?.instances.isEmpty == true)
        #expect(owner.children.allSatisfy { $0.components[Mesh3DInstancesComponent.self] == nil })
    }

    @Test("Mesh erase removes only covered placements and its inverse restores exact record order and IDs")
    func meshBrushEraseAndUndo() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, owner, storage, _) = try await instancePaintFixture(in: directory)
        var settings = instancePaintSettings()
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: instancePaintStroke(settings))
        await settle(app)
        let rows = try #require(try storage.regionAsset(at: .init(x: 0, z: 0))).instances
        try #require(rows.count > 8)
        settings.operation = .erase
        settings.radius = 2
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: instancePaintStroke(settings))
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
        let remaining = try #require(try storage.regionAsset(at: .init(x: 0, z: 0))).instances
        #expect(!remaining.isEmpty && remaining.count < rows.count)
        for row in remaining {
            let x = row.localPosition.x - 20, z = row.localPosition.z - 20
            #expect(x * x + z * z >= 4)
        }
        let delta = try #require(owner.components[Terrain3DEditStatus.self]?.delta)
        owner.components[Terrain3DEdit.self] = .init(storage: storage, undoing: delta)
        await settle(app)
        #expect(try storage.regionAsset(at: .init(x: 0, z: 0))?.instances == rows)
    }

    @Test("Mesh paint is invariant to collinear input event subdivision")
    func meshBrushEventSubdivisionIsStable() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, owner, storage, _) = try await instancePaintFixture(in: directory)
        let settings = instancePaintSettings()
        let start = TerrainBrushPoint(position: [20, 2, 20], time: 0)
        let middle = TerrainBrushPoint(position: [24, 2, 20], time: 0.5)
        let end = TerrainBrushPoint(position: [28, 2, 20], time: 1)
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: instancePaintStroke(settings, points: [start, end]))
        await settle(app)
        let rows = try #require(try storage.regionAsset(at: .init(x: 0, z: 0))).instances
        try #require(!rows.isEmpty)
        let delta = try #require(owner.components[Terrain3DEditStatus.self]?.delta)
        owner.components[Terrain3DEdit.self] = .init(storage: storage, undoing: delta)
        await settle(app)
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: instancePaintStroke(settings, points: [start, middle, end]))
        await settle(app)
        #expect(try storage.regionAsset(at: .init(x: 0, z: 0))?.instances == rows)
    }

    @Test("Mesh paint height and slope filters use the authored surface and preserve normal alignment")
    func meshBrushFiltersAndAlignment() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, owner, storage, _) = try await instancePaintFixture(in: directory, sloped: true)
        var settings = instancePaintSettings()
        let revision = storage.revision
        settings.heightRange = 0...5
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: instancePaintStroke(settings))
        await settle(app)
        #expect(storage.revision == revision)
        settings.heightRange = 18...22
        settings.slopeRange = 0...10
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: instancePaintStroke(settings))
        await settle(app)
        #expect(storage.revision == revision)
        settings.slopeRange = 40...50
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: instancePaintStroke(settings))
        await settle(app)
        let rows = try #require(try storage.regionAsset(at: .init(x: 0, z: 0))).instances
        try #require(!rows.isEmpty)
        for row in rows {
            #expect((18...22).contains(row.localPosition.y - settings.heightOffset))
            #expect(row.anchorNormal.dot(Vector3(-1, 1, 0).normalized) > 0.9999)
            #expect(Transform3D(translation: .zero, rotation: row.rotation, scale: .one).y.xyz.dot(row.anchorNormal) > 0.9999)
        }
    }

    @Test("Invalid or oversized mesh paint and missing prototype assets fail without modifying published terrain")
    func meshBrushFailuresAreAtomic() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, owner, storage, _) = try await instancePaintFixture(in: directory)
        let revision = storage.revision
        let before = try buffers(owner)
        var bad = instancePaintSettings()
        bad.minimumDistance = 0
        var huge = instancePaintSettings()
        huge.radius = 100; huge.density = 1_000; huge.minimumDistance = 0.05
        for settings in [bad, huge] {
            owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: instancePaintStroke(settings))
            await settle(app)
            #expect(owner.components[Terrain3DEditStatus.self]?.phase == .failed)
            #expect(storage.revision == revision)
            #expect(try buffers(owner) == before)
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("rock.gltf"))
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: instancePaintStroke(instancePaintSettings()))
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .failed)
        #expect(storage.revision == revision)
        #expect(owner.children.allSatisfy { $0.components[Mesh3DInstancesComponent.self] == nil })
    }

    @Test("Changing scatter spacing does not collide with IDs from a distant patch")
    func meshBrushScaleChangeKeepsDistinctPlacements() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, owner, storage, _) = try await instancePaintFixture(in: directory)
        var settings = instancePaintSettings()
        settings.minimumDistance = 1
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: instancePaintStroke(settings))
        await settle(app)
        let original = try #require(try storage.regionAsset(at: .init(x: 0, z: 0))).instances
        try #require(!original.isEmpty)
        settings.minimumDistance = 2
        settings.radius = 8
        let points = [TerrainBrushPoint(position: [40, 2, 40], time: 0)]
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: instancePaintStroke(settings, points: points))
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
        let result = try #require(try storage.regionAsset(at: .init(x: 0, z: 0))).instances
        #expect(result.count > original.count)
        #expect(result.filter { $0.localPosition.x < 30 } == original)
        #expect(result.contains { $0.localPosition.x > 32 && $0.localPosition.z > 32 })
        #expect(Set(result.map(\.id)).count == result.count)
        let secondDelta = try #require(owner.components[Terrain3DEditStatus.self]?.delta)
        owner.components[Terrain3DEdit.self] = .init(storage: storage, undoing: secondDelta)
        await settle(app)
        owner.components[Terrain3DEdit.self] = .init(
            storage: storage,
            instances: [
                .init(coordinate: .init(x: 0, z: 0), previous: original, instances: [])
            ]
        )
        await settle(app)
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: instancePaintStroke(settings, points: points))
        await settle(app)
        let standalone = try #require(try storage.regionAsset(at: .init(x: 0, z: 0))).instances
        #expect(result.filter { $0.localPosition.x > 32 } == standalone)
    }

    @Test("Repeated small dabs meter every existing placement bounds check and fail atomically")
    func meshBrushReadBoundsRespectWorkBudget() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var original: [TerrainRegionInstance] = []
        for index in 0..<20_000 {
            let x = Float(50) + Float(index % 100) * Float(0.001)
            let z = Float(50) + Float(index / 100) * Float(0.001)
            original.append(try TerrainRegionInstance(id: UInt64(index + 1), prototypeID: 17, localPosition: [x, 2, z]))
        }
        let (app, owner, storage, _) = try await instancePaintFixture(in: directory, instances: original)
        let revision = storage.revision
        let before = try buffers(owner)
        let children = Set(owner.children.map(\.id))
        var settings = instancePaintSettings()
        settings.radius = 0.1
        settings.minimumDistance = 1
        settings.spacing = 0.01
        let points = (0..<4_096).map { index in
            TerrainBrushPoint(position: [20 + Float(index % 2) * 0.001, 2, 20], time: Double(index) * 0.001)
        }
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: instancePaintStroke(settings, points: points))
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .failed)
        #expect(storage.revision == revision)
        #expect(try storage.regionAsset(at: .init(x: 0, z: 0))?.instances == original)
        #expect(try buffers(owner) == before)
        #expect(Set(owner.children.map(\.id)) == children)
    }
}
