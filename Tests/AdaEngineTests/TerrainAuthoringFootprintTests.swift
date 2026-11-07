@_spi(Internal) @testable import AdaApp
import AdaEngine
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    private func authoringFootprintFixture(in directory: URL, missingLast: Bool = false, maximumRegions: Int = 128) async throws -> (AppWorlds, Entity, TerrainHeightStorage, URL) {
        try terrainGLTFDocument(normals: 3).write(to: directory.appendingPathComponent("rock.gltf"))
        let nearAnchor = try TerrainRegionInstance(id: 70, prototypeID: 17, localPosition: [4, 0, 128], flags: [.anchored])
        let farAnchor = try TerrainRegionInstance(id: 80, prototypeID: 17, localPosition: [2, 0, 128], flags: [.anchored])
        let middle = (0..<4).flatMap { z in (0..<4).map { x in TerrainRegionTile(x: UInt8(x), z: UInt8(z)) } }
        let regions = [
            TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 3, z: 1), .init(x: 3, z: 2)], pages: []),
            TerrainRegionAsset(x: 1, z: 0, tiles: middle, pages: [], instances: [nearAnchor]),
            TerrainRegionAsset(x: 2, z: 0, tiles: [.init(x: 0, z: 1), .init(x: 0, z: 2)], pages: [], instances: [farAnchor]),
        ]
        let file = directory.appendingPathComponent("world.aterrain")
        let saved = try await AssetsManager.saveTerrainRegions(regions, manifest: .init(meshPrototypes: [.init(id: 17, assetPath: "rock.gltf")]), at: file.path)
        if missingLast {
            let reference = try #require(saved.heightRegions.first { $0.x == 2 })
            try FileManager.default.removeItem(at: directory.appendingPathComponent(reference.fileName))
        }
        let app = try await makeApp()
        let owner = app.main.spawn("Terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumResidentRegions: maximumRegions, maximumLOD: 0, streamingRadius: 5)
        }
        _ = app.main.spawn("Camera") {
            Transform(position: [250, 20, 128]); Camera()
        }
        await settle(app)
        try #require(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        return (app, owner, try #require(owner.components[Terrain3DSourceSurface.self]?.storage), file)
    }

    private func rampAcrossAuthoringRegions() -> TerrainHeightBrushStroke {
        TerrainHeightBrushStroke(
            settings: .init(operation: .ramp, radius: 4, strength: 1),
            points: [
                .init(position: [250, 0, 128], time: 0), .init(position: [514, 4, 128], time: 1),
            ]
        )
    }

    @Test("A brush edits a normal-only neighboring surface and its anchors without exposing hidden draw tiles")
    func brushPromotesCompleteNormalHaloFootprint() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, owner, storage, file) = try await authoringFootprintFixture(in: directory)
        let visible = storage.tileCoordinates
        var settings = TerrainHeightBrushSettings(operation: .raise, radius: 16, strength: 60)
        settings.shape = .hardRound
        let stroke = TerrainHeightBrushStroke(settings: settings, points: [.init(position: [250, 0, 128], time: 0), .init(position: [250, 0, 128], time: 1.0 / 60)])
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: stroke)
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
        let delta = try #require(owner.components[Terrain3DEditStatus.self]?.delta)
        #expect(delta.changes.contains { $0.point == .init(x: 260, z: 128) })
        let hidden = try #require(try storage.regionAsset(at: .init(x: 1, z: 0)))
        let page = try #require(hidden.pages.first { $0.x == 0 && $0.z == 2 })
        #expect(page.samples[4] > 0.9)
        #expect(hidden.instances.first { $0.id == 70 }?.localPosition.y ?? 0 > 0.9)
        #expect(storage.tileCoordinates == visible)
        #expect(owner.children.allSatisfy { $0.components[Mesh3DInstancesComponent.self] == nil })
        owner.components[Terrain3DSave.self] = .init(storage: storage)
        await finishSave(app, owner: owner)
        #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        let manifest = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        let reference = try #require(manifest.heightRegions.first { $0.x == 1 })
        let saved = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: directory.appendingPathComponent(reference.fileName).path)
        #expect(saved.tiles.count == 16)
        #expect(saved.pages.first { $0.x == 0 && $0.z == 2 }?.samples[4] ?? 0 > 0.9)
        owner.components[Terrain3DEdit.self] = .init(storage: storage, undoing: delta)
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
        #expect(storage.tileCoordinates == visible)
        #expect(try storage.regionAsset(at: .init(x: 1, z: 0))?.pages.isEmpty == true)
        #expect(try storage.regionAsset(at: .init(x: 1, z: 0))?.instances.first { $0.id == 70 }?.localPosition.y == 0)
    }

    @Test("A complete ramp hydrates declared regions beyond the render/normal working set before evaluating the gesture")
    func brushHydratesDistantDeclaredFootprint() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, owner, storage, _) = try await authoringFootprintFixture(in: directory)
        let visible = storage.tileCoordinates
        #expect(!storage.resourceCoordinates.contains(.init(x: 2, z: 0)))
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: rampAcrossAuthoringRegions())
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
        #expect(owner.components[Terrain3DEditStatus.self]?.delta?.changes.contains { $0.point == .init(x: 514, z: 128) } == true)
        let hidden = try #require(try storage.regionAsset(at: .init(x: 2, z: 0)))
        #expect(hidden.pages.first { $0.x == 0 && $0.z == 2 }?.samples[2] ?? 0 > 0.01)
        #expect(hidden.instances.first { $0.id == 80 }?.localPosition.y ?? 0 > 0.01)
        #expect(storage.tileCoordinates == visible)
        #expect(owner.children.allSatisfy { $0.components[Mesh3DInstancesComponent.self] == nil })
    }

    @Test("A missing footprint payload or insufficient complete working-set budget rejects the whole brush", arguments: [(true, 128), (false, 2)])
    func brushFootprintFailuresAreAtomic(missingLast: Bool, maximumRegions: Int) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, owner, storage, _) = try await authoringFootprintFixture(in: directory, missingLast: missingLast, maximumRegions: maximumRegions)
        let revision = storage.revision
        let before = try buffers(owner)
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: rampAcrossAuthoringRegions())
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .failed)
        #expect(owner.components[Terrain3DEditStatus.self]?.error != nil)
        #expect(storage.revision == revision)
        #expect(storage.height(atSample: .init(x: 252, z: 128)) == 0)
        #expect(try buffers(owner) == before)
        #expect(!storage.resourceCoordinates.contains(.init(x: 2, z: 0)))
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
    }
}
