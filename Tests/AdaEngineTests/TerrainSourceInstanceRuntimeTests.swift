@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Streamed terrain placements share imported buffers per cell and preserve stable transforms and lifecycle")
    func streamsSharedPlacementCells() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try terrainGLTFDocument(normals: 3).write(to: directory.appendingPathComponent("rock.gltf"))
        let records = try [
            TerrainRegionInstance(id: 101, prototypeID: 17, localPosition: [10, 3, 10], scale: [-1, 2, 1], tint: [0.4, 0.6, 0.8, 1], flags: []),
            TerrainRegionInstance(id: 102, prototypeID: 17, localPosition: [12, 4, 10], flags: []),
            TerrainRegionInstance(id: 103, prototypeID: 17, localPosition: [70, 5, 10], flags: []),
        ]
        let distant = try TerrainRegionInstance(id: 104, prototypeID: 17, localPosition: [10, 6, 10], flags: [])
        let regions = [
            TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0)], pages: [], instances: records),
            TerrainRegionAsset(x: 4, z: 0, tiles: [], pages: [], instances: [distant]),
        ]
        let file = directory.appendingPathComponent("world.aterrain")
        let manifest = TerrainManifestAsset(spacing: 2, originX: -8, originZ: 12, meshPrototypes: [.init(id: 17, assetPath: "rock.gltf", maximumDistance: 500)])
        try await AssetsManager.saveTerrainRegions(regions, manifest: manifest, at: file.path)
        let app = try await makeApp()
        var source = Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: 20)
        let owner = app.main.spawn("Terrain") {
            Transform(); source
        }
        let camera = app.main.spawn("Camera") {
            Transform(position: [12, 20, 32]); Camera()
        }
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        let cells = owner.children.filter { $0.components[Mesh3DInstancesComponent.self] != nil }
        #expect(cells.count == 2)
        let batches = cells.compactMap { $0.components[Mesh3DInstancesComponent.self] }
        #expect(batches.flatMap(\.instances).map(\.id).sorted() == [101, 102, 103])
        let first = try #require(batches.first)
        let vertexBuffer = try #require(first.mesh.models.first?.parts.first?.vertexBuffer)
        for child in cells {
            #expect(child.components[TransientEntity.self] != nil)
            #expect(child.components[MeshLOD3DComponent.self]?.maximumDistance == 500)
            let batch = try #require(child.components[Mesh3DInstancesComponent.self])
            #expect(batch.mesh.models.first?.parts.first?.vertexBuffer === vertexBuffer)
            #expect(batch.materials.first === first.materials.first)
            for placement in batch.instances {
                let record = try #require(records.first { $0.id == placement.id })
                #expect(
                    placement.transform
                        == Transform3D(
                            translation: [-8 + record.localPosition.x * 2, record.localPosition.y * 2, 12 + record.localPosition.z * 2],
                            rotation: record.rotation,
                            scale: record.scale
                        )
                )
                #expect(placement.color == record.tint)
            }
        }
        let identities = Set(cells.map(\.id))
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        try storage.setHeight(7, at: .init(x: 10, z: 10))
        await settle(app)
        #expect(Set(owner.children.filter { $0.components[Mesh3DInstancesComponent.self] != nil }.map(\.id)) == identities)
        camera.components[Transform.self] = Transform(position: [2_060, 20, 32])
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(owner.children.compactMap { $0.components[Mesh3DInstancesComponent.self] }.flatMap(\.instances).map(\.id) == [104])
        camera.components[Transform.self] = Transform(position: [12, 20, 32])
        await settle(app)
        #expect(owner.children.compactMap { $0.components[Mesh3DInstancesComponent.self] }.flatMap(\.instances).map(\.id).sorted() == [101, 102, 103])
        source.source = directory.appendingPathComponent("missing.aterrain").path
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.error != nil)
        #expect(owner.children.compactMap { $0.components[Mesh3DInstancesComponent.self] }.flatMap(\.instances).map(\.id).sorted() == [101, 102, 103])
        owner.components.remove(Terrain3DSource.self)
        await settle(app)
        #expect(owner.children.isEmpty)
    }
}
