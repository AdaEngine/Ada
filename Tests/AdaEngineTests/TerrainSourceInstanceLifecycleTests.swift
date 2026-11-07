@_spi(Internal) @testable import AdaApp
@testable import AdaCorePipelines
import AdaEngine
@_spi(Internal) @testable import AdaRender
@testable import AdaScene
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    private func instanceFixture(in directory: URL, distant: Bool = false) async throws -> URL {
        try terrainGLTFDocument(normals: 3).write(to: directory.appendingPathComponent("rock.gltf"))
        var regions = [TerrainRegionAsset(x: 0, z: 0, tiles: [], pages: [], instances: [try .init(id: 1, prototypeID: 17, localPosition: [10, 0, 10], flags: [])])]
        if distant { regions.append(.init(x: 4, z: 0, tiles: [], pages: [], instances: [try .init(id: 2, prototypeID: 18, localPosition: [10, 0, 10], flags: [])])) }
        let file = directory.appendingPathComponent("world.aterrain")
        let palette: [TerrainMeshPrototypeReference] = [.init(id: 17, assetPath: "rock.gltf", maximumDistance: 500), .init(id: 18, assetPath: "rock.gltf")]
        try await AssetsManager.saveTerrainRegions(regions, manifest: .init(meshPrototypes: palette), at: file.path)
        return file
    }

    @Test("Clearing and restoring the terrain URI removes all old draw cells without orphaning instances")
    func clearingSourceRemovesInstanceCells() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await instanceFixture(in: directory)
        let app = try await makeApp()
        var source = Terrain3DSource(source: file.path, generatesCollision: false)
        let owner = app.main.spawn("Terrain") {
            Transform(); source
        }
        await settle(app)
        #expect(owner.children.count == 1)
        source.source = ""
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.children.isEmpty)
        #expect(owner.components[Terrain3DSourceSurface.self] == nil)
        source.source = file.path
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.children.count == 1)
        #expect(owner.children.compactMap { $0.components[Mesh3DInstancesComponent.self] }.flatMap(\.instances).map(\.id) == [1])
    }

    @Test("Camera-only jobs reuse 100000 immutable placements without regrouping their rows")
    func cameraMotionReusesHundredThousandPlacements() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try terrainGLTFDocument(normals: 3).write(to: directory.appendingPathComponent("rock.gltf"))
        var regions: [TerrainRegionAsset] = []
        for region in 0..<2 {
            let records = try (0..<50_000).map { index in
                try TerrainRegionInstance(id: UInt64(region * 50_000 + index), prototypeID: 17, localPosition: [Float(index % 256) + 0.25, 0, Float(index / 256) + 0.25], flags: [])
            }
            regions.append(.init(x: Int32(region), z: 0, tiles: [], pages: [], instances: records))
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
        let initial = try #require(owner.components[TerrainSourceState.self])
        #expect(initial.groupedInstanceRecordCount == 100_000)
        #expect(initial.instanceCells.values.flatMap(\.prepared.batches).reduce(0) { $0 + $1.instances.count } == 100_000)
        #expect(owner.children.count == 32)
        let identities = initial.instanceCells.mapValues(\.prepared.id)
        for x: Float in [256, 257, 258] {
            camera.components[Transform.self] = Transform(position: [x, 30, 128])
            await settle(app)
            let current = try #require(owner.components[TerrainSourceState.self])
            #expect(current.groupedInstanceRecordCount == 0)
            #expect(current.instanceCells.mapValues(\.prepared.id) == identities)
            #expect(current.focus?.cameras.first?.x == x)
        }
    }

    @Test("Streaming releases inactive prototypes and shared geometry is charged before draw publication")
    func instancePrototypeResidencyAndGeometryBudget() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await instanceFixture(in: directory, distant: true)
        let app = try await makeApp()
        let owner = app.main.spawn("Terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: 20)
        }
        let camera = app.main.spawn("Camera") {
            Transform(position: [10, 20, 10]); Camera()
        }
        await settle(app)
        #expect(owner.components[TerrainSourceState.self]?.residency?.prototypes.count == 1)
        camera.components[Transform.self] = Transform(position: [1_034, 20, 10])
        await settle(app)
        let state = try #require(owner.components[TerrainSourceState.self])
        #expect(state.residency?.prototypes.count == 1)
        #expect(state.residency?.prototypes[17] == nil && state.residency?.prototypes[18] != nil)
        let tiny = app.main.spawn("Insufficient geometry budget") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumMeshBytes: MemoryLayout<Mesh3DInstance>.stride, maximumLOD: 0, streamingRadius: 20)
        }
        await settle(app)
        #expect(tiny.components[Terrain3DSourceStatus.self]?.error != nil)
        #expect(tiny.children.isEmpty)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
    }

    @Test("Palette draw distances use the existing world-space LOD metric under scaled terrain owners")
    func placementDistanceUsesWorldMetric() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await instanceFixture(in: directory)
        let app = try await makeApp()
        let owner = app.main.spawn("Terrain") {
            Transform(scale: [2, 2, 2]); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
        }
        await settle(app)
        let render = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
        render.insertResource(MainWorld(world: app.main))
        var lists = VisibleMesh3DLists(), uniforms = PBR3DUniforms()
        for (scale, count): (Float, Int) in [(2, 1), (60, 0)] {
            owner.components[Transform.self] = Transform(scale: [scale, scale, scale])
            await settle(app)
            await app.main.runScheduler(.postUpdate)
            await render.runScheduler(.extract)
            let sources = try #require(render.getResource(ExtractedMesh3DSources.self)).meshes
            #expect(sources.count == 1)
            uniforms.beginFrame()
            lists.prepare(
                sources: sources,
                view: owner.id,
                pass: -1,
                viewMatrix: .identity,
                projection: .identity,
                cullingProjection: .identity,
                settings: .init(frustumCulling: false, lod: false, distanceCulling: true),
                device: unsafe RenderEngine.shared.renderDevice,
                materials: &uniforms
            )
            #expect(lists.count(view: owner.id, pass: -1).visibleMeshes == count)
        }
    }
}
