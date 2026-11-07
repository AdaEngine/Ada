@_spi(Internal) @testable import AdaApp
import AdaAssets
import AdaECS
import AdaGeometry
import AdaPhysics
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaTransform
import Foundation
import Math
import Testing

@MainActor @Suite("Mesh terrain runtime", .serialized)
struct MeshTerrainRuntimeTests {
    @Test("Adjacent palette terrain tiles preserve identical edges across meshlet LODs")
    func publishedMeshletLODHasWatertightMixedSectionEdges() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaTerrainLOD-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ground = try TriangleSurface.ground(size: [24, 24], cells: 16)
        let sections = try [Float(-12), 12].map { x in
            MeshTerrainBaseSection(surface: try ground.transformed(by: .init(translation: [x, 0, 0])), closure: .ground(bottomHeight: -4))
        }
        let asset = try await MeshTerrainDocumentAsset(document: .init(sections: sections)).compiling()
        try asset.encodedData().write(to: directory.appendingPathComponent("ground.atmesh"))
        let palette = TerrainMaterialPalette(layers: [.init(id: 1, name: "Grass")], fallbackLayerID: 1)
        let file = directory.appendingPathComponent("ground.aterrain")
        try TerrainManifestAsset(materials: palette, meshDocumentFileName: "ground.atmesh").encodedData().write(to: file)
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        let owner = app.main.spawn("Terrain") { Transform(); Terrain3DSource(source: file.path, generatesCollision: false) }
        try await settle(app, owner: owner)
        let parts = owner.children.compactMap { $0.components[Mesh3DComponent.self] }.flatMap { $0.mesh.models.flatMap(\.parts) }
        try #require(parts.count == 2)

        func seam(_ indices: [UInt32], positions: [Vector3]) -> Set<[Float]> {
            var edges: Set<[Float]> = []
            for i in stride(from: 0, to: indices.count, by: 3) {
                for corner in 0..<3 {
                    let a = positions[Int(indices[i + corner])], b = positions[Int(indices[i + (corner + 1) % 3])]
                    if a.x == 0, b.x == 0 { edges.insert([min(a.z, b.z), max(a.z, b.z)]) }
                }
            }
            return edges
        }

        var shared: Set<[Float]>?
        for part in parts {
            let lod = try #require(part.meshletLOD)
            let source = part.meshDescriptor.indicies
            let positions = part.meshDescriptor.positions.elements
            let coarsest = lod.roots.flatMap { id in
                let node = lod.nodes[id]
                return lod.geometry.clusters[node.firstCluster..<(node.firstCluster + node.clusterCount)].flatMap { cluster in
                    lod.geometry.indices[cluster.firstIndex..<(cluster.firstIndex + cluster.indexCount)]
                }
            }
            #expect(coarsest.count < source.count)
            let fine = seam(source, positions: positions)
            #expect(fine.count == 16)
            #expect(seam(coarsest, positions: positions) == fine)
            if let shared { #expect(shared == fine) } else { shared = fine }
        }
    }

    @Test("Joined bark keeps its source color, roughness and UVs after publication and reopen",
          .enabled(if: TriangleMeshBoolean.isAvailable))
    func joinedBarkRetainsAppearance() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaMeshBark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ground = try TriangleSurface.ground(size: [12, 8], cells: 6)
        let initial = try await MeshTerrainDocumentAsset(document: .init(sections: [.init(surface: ground, closure: .ground(bottomHeight: -4))])).compiling()
        let file = directory.appendingPathComponent("ground.aterrain")
        try initial.encodedData().write(to: directory.appendingPathComponent("ground.atmesh"))
        try TerrainManifestAsset(meshDocumentFileName: "ground.atmesh").encodedData().write(to: file)
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        let ownerID = UUID()
        let owner = app.main.spawn("Ground") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, queries: .init()); MeshTerrain3DIdentity(id: ownerID)
        }
        let trunk = try TriangleSurface.box(minimum: [-1, -1, -1], maximum: [1, 2, 1])
        let uv = Vector2(0.23, 0.71)
        var descriptor = MeshDescriptor(name: "Bark")
        descriptor.positions = .init(trunk.positions)
        descriptor.indicies = trunk.indices
        descriptor.textureCoordinates = .init(Array(repeating: uv, count: trunk.positions.count))
        let mesh = Mesh.generate(from: [descriptor], renderDevice: unsafe RenderEngine.shared.renderDevice)
        let bark = PBRMaterial()
        bark.baseColorFactor = [0.39, 0.12, 0.035, 1]
        bark.roughnessFactor = 0.72
        bark.metallicFactor = 0.1
        let tree = app.main.spawn("Tree") {
            Transform(); MeshTerrain3DIdentity(id: UUID()); Mesh3DComponent(mesh: mesh, materials: [bark])
        }
        try await settle(app, owner: owner)
        tree.components[MeshTerrain3DBinding.self] = .init(target: ownerID, modifier: UUID(), sourceID: 17)
        try await settleBinding(app, source: tree)
        try #require(tree.components[MeshTerrain3DBindingStatus.self]?.phase == .applied)
        let joined = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.asset)
        let old = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.queries)
        #expect(try old.raycast(.init(origin: [0, 4, 0], direction: [0, -1, 0]))?.position.y == 2)
        let compiled = try joined.acceptedCompiledProduct()
        let expectedIndices = compiled.patches.reduce(0) { $0 + $1.surface.faceSources.filter { $0 == 17 }.count * 3 }
        try #require(expectedIndices > 0)

        let reloadedFile = directory.appendingPathComponent("joined.aterrain")
        try joined.encodedData().write(to: directory.appendingPathComponent("joined.atmesh"))
        try TerrainManifestAsset(meshDocumentFileName: "joined.atmesh").encodedData().write(to: reloadedFile)
        let reopened = app.main.spawn("Reloaded terrain") {
            Transform(position: [20, 0, 0]); Terrain3DSource(source: reloadedFile.path, generatesCollision: false, queries: .init())
        }
        try await settle(app, owner: reopened)
        for terrain in [owner, reopened] {
            let draw = try #require(terrain.children.compactMap { $0.components[Mesh3DComponent.self] }.first)
            let matching = draw.mesh.models.flatMap(\.parts).filter { part in
                guard draw.materials.indices.contains(part.materialIndex), let material = draw.materials[part.materialIndex] as? PBRMaterial else { return false }
                return material.baseColorFactor == bark.baseColorFactor && material.roughnessFactor == 0.72 && material.metallicFactor == 0.1
            }
            #expect(matching.reduce(0) { $0 + $1.indexCount } == expectedIndices)
            #expect(matching.contains { $0.meshDescriptor.textureCoordinates?.elements.allSatisfy { abs($0.x - uv.x) < 0.0001 && abs($0.y - uv.y) < 0.0001 } == true })
        }
    }

    @Test(.enabled(if: TriangleMeshBoolean.isAvailable)) func immutableResourceAdoptionPublishesWithGeometryAndPose() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaMeshAdoption-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try await MeshTerrainDocumentAsset(document: .init(sections: [
            .init(surface: try TriangleSurface.ground(size: [12, 8], cells: 6), closure: .ground(bottomHeight: -4))
        ])).compiling()
        let file = directory.appendingPathComponent("world.aterrain"), fork = directory.appendingPathComponent("edit.aterrain")
        try initial.encodedData().write(to: directory.appendingPathComponent("ground.atmesh"))
        try TerrainManifestAsset(heightRegions: [], meshDocumentFileName: "ground.atmesh").encodedData().write(to: file)
        var document = initial.document
        document.modifiers.append(.init(sourceID: 1, operation: .union,
            surface: try TriangleSurface.box(minimum: [-1, -1, -1], maximum: [1, 2, 1]), transform: .init(translation: [3, 0, 0])))
        let joined = try await MeshTerrainDocumentAsset(document: document).compiling()
        try joined.encodedData().write(to: directory.appendingPathComponent("joined.atmesh"))
        try TerrainManifestAsset(heightRegions: [], meshDocumentFileName: "joined.atmesh").encodedData().write(to: fork)
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        let owner = app.main.spawn("Terrain") { Transform(); Terrain3DSource(source: file.path, generatesCollision: false, queries: .init()) }
        let object = app.main.spawn("Retained source") { Transform() }
        try await settle(app, owner: owner)
        let edit = MeshTerrain3DEdit(expectedInputKey: try initial.authoringKey(), candidate: joined,
            sourceTransforms: [.init(entity: object.id, pose: Transform(position: [3, 0, 0]))], adoptionManifest: fork.path)
        owner.components[MeshTerrain3DEdit.self] = edit
        #expect(owner.components[Terrain3DSource.self]?.source == file.path)
        for _ in 0..<2_000 {
            await app.main.runScheduler(.preUpdate)
            if owner.components[Terrain3DSource.self]?.source == fork.path {
                #expect(object.components[Transform.self]?.position.x == 3)
                #expect(try owner.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(.init(origin: [3, 5, 0], direction: [0, -1, 0]))?.position.y == 2)
            }
            if owner.components[MeshTerrain3DEditStatus.self]?.id == edit.id,
                owner.components[MeshTerrain3DEditStatus.self]?.phase != .pending { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(owner.components[MeshTerrain3DEditStatus.self]?.phase == .applied)
        #expect(owner.components[Terrain3DSource.self]?.source == fork.path)
        // The adopted resource is already the resident generation: subsequent updates must not reload it.
        let queries = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.queries)
        for _ in 0..<12 { await app.main.runScheduler(.preUpdate) }
        #expect(try owner.components[MeshTerrain3DSourceSurface.self]?.asset.authoringKey() == joined.authoringKey())
        #expect(try queries.raycast(.init(origin: [3, 5, 0], direction: [0, -1, 0]))?.position.y == 2)
        let invalid = MeshTerrain3DEdit(expectedInputKey: try joined.authoringKey(), candidate: joined,
            sourceTransforms: [.init(entity: object.id, pose: Transform(position: [5, 0, 0]))], adoptionManifest: file.path)
        owner.components[MeshTerrain3DEdit.self] = invalid
        try await settleEdit(app, owner: owner, id: invalid.id)
        #expect(owner.components[MeshTerrain3DEditStatus.self]?.phase == .failed)
        #expect(owner.components[Terrain3DSource.self]?.source == fork.path)
        #expect(object.components[Transform.self]?.position.x == 3)
    }

    @Test(.enabled(if: TriangleMeshBoolean.isAvailable)) func movedJoinPublishesSurfaceQueriesAndSourcePoseTogether() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaMeshMove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ground = try TriangleSurface.ground(size: [12, 8], cells: 6)
        let rock = try TriangleSurface.box(minimum: [-1, -1, -1], maximum: [1, 2, 1])
        let initial = try await MeshTerrainDocumentAsset(document: .init(sections: [.init(surface: ground, closure: .ground(bottomHeight: -4))],
            modifiers: [.init(sourceID: 1, operation: .union, surface: rock)])).compiling()
        try initial.encodedData().write(to: directory.appendingPathComponent("ground.atmesh"))
        let file = directory.appendingPathComponent("world.aterrain")
        try TerrainManifestAsset(heightRegions: [], meshDocumentFileName: "ground.atmesh").encodedData().write(to: file)
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        let owner = app.main.spawn("Joined Terrain") { Transform(); Terrain3DSource(source: file.path, generatesCollision: false, queries: .init()) }
        var originalDescriptor = MeshDescriptor(name: "Editable source rock")
        originalDescriptor.positions = .init(rock.positions); originalDescriptor.indicies = rock.indices
        let originalMesh = Mesh.generate(from: [originalDescriptor], renderDevice: unsafe RenderEngine.shared.renderDevice)
        let object = app.main.spawn("Retained rock") { Transform(); Mesh3DComponent(mesh: originalMesh, materials: [PBRMaterial()]) }
        try await settle(app, owner: owner)
        let before = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.queries)
        #expect(try before.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.position.y == 2)
        var moved = initial.document
        moved.modifiers[0].transform = .init(translation: [3, 0, 0])
        let edit = MeshTerrain3DEdit(expectedInputKey: try initial.authoringKey(), candidate: .init(document: moved),
            sourceTransforms: [.init(entity: object.id, transform: .init(translation: [3, 0, 0], rotation: .identity, scale: [-1, 1, 1]))], drawReplacements: [.init(entity: object.id)])
        owner.components[MeshTerrain3DEdit.self] = edit
        #expect(object.components[Transform.self]?.position.x == 0)
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            if let status = owner.components[MeshTerrain3DEditStatus.self], status.id == edit.id, status.phase != .pending { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(owner.components[MeshTerrain3DEditStatus.self]?.phase == .applied)
        let after = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.queries)
        #expect(after.revision != before.revision)
        #expect(try after.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.position.y == 0)
        #expect(try after.raycast(.init(origin: [3, 5, 0], direction: [0, -1, 0]))?.position.y == 2)
        #expect(object.components[Transform.self]?.position.x == 3)
        #expect(object.components[Transform.self]?.matrix.x.x == -1)
        #expect(object.components[MeshTerrain3DSourceMask.self]?.owner == owner.id)
        #expect(object.components[Mesh3DComponent.self]?.mesh.models[0].parts[0].indexCount == rock.indices.count)
        #expect(try before.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.position.y == 2)
        var settings = try #require(owner.components[Terrain3DSource.self])
        settings.color = [0.2, 0.3, 0.4, 1]
        owner.components[Terrain3DSource.self] = settings
        try await settle(app, owner: owner)
        let presented = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.queries)
        #expect(presented.revision == after.revision)
        #expect(presented.tileGeneration(at: .init(x: 0, z: 0)) == after.tileGeneration(at: .init(x: 0, z: 0)))
        #expect(try presented.raycast(.init(origin: [3, 5, 0], direction: [0, -1, 0]))?.position.y == 2)
        let accepted = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.asset)
        var invalid = moved
        invalid.modifiers[0].surface = try TriangleSurface.ground(size: [2, 2], cells: 2)
        let failed = MeshTerrain3DEdit(expectedInputKey: try accepted.authoringKey(), candidate: .init(document: invalid),
            sourceTransforms: [.init(entity: object.id, transform: .init(translation: [5, 0, 0]))])
        owner.components[MeshTerrain3DEdit.self] = failed
        try await settleEdit(app, owner: owner, id: failed.id)
        #expect(owner.components[MeshTerrain3DEditStatus.self]?.phase == .failed)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(object.components[Transform.self]?.position.x == 3)
        #expect(try owner.components[MeshTerrain3DSourceSurface.self]?.asset.authoringKey() == accepted.authoringKey())

        let removed = app.main.spawn("Removed during preparation")
        let removedID = removed.id
        app.main.removeEntity(removedID)
        var missing = moved
        missing.modifiers[0].transform = .init(translation: [-3, 0, 0])
        let disappeared = MeshTerrain3DEdit(expectedInputKey: try accepted.authoringKey(), candidate: .init(document: missing),
            sourceTransforms: [.init(entity: removedID, transform: .identity)])
        owner.components[MeshTerrain3DEdit.self] = disappeared
        try await settleEdit(app, owner: owner, id: disappeared.id)
        #expect(owner.components[MeshTerrain3DEditStatus.self]?.phase == .failed)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(try owner.components[MeshTerrain3DSourceSurface.self]?.asset.authoringKey() == accepted.authoringKey())
        var detached = moved
        detached.modifiers[0].enabled = false
        let detach = MeshTerrain3DEdit(expectedInputKey: try accepted.authoringKey(), candidate: .init(document: detached), drawReplacements: [])
        owner.components[MeshTerrain3DEdit.self] = detach
        try await settleEdit(app, owner: owner, id: detach.id)
        #expect(owner.components[MeshTerrain3DEditStatus.self]?.phase == .applied)
        #expect(object.components[MeshTerrain3DSourceMask.self] == nil)
        let detachedAsset = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.asset)
        let rejoin = MeshTerrain3DEdit(expectedInputKey: try detachedAsset.authoringKey(), candidate: .init(document: moved),
                                     drawReplacements: [.init(entity: object.id)])
        owner.components[MeshTerrain3DEdit.self] = rejoin
        try await settleEdit(app, owner: owner, id: rejoin.id)
        try #require(object.components[MeshTerrain3DSourceMask.self] != nil)
        owner.components.remove(Terrain3DSource.self)
        for _ in 0..<4 { await app.main.runScheduler(.preUpdate) }
        #expect(object.components[MeshTerrain3DSourceMask.self] == nil)
        #expect(object.components[Mesh3DComponent.self]?.mesh.models[0].parts[0].indexCount == rock.indices.count)
    }

    @Test(.enabled(if: TriangleMeshBoolean.isAvailable)) func retainedBindingCapturesHierarchyAndMovesWithoutDestructiveAccumulation() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaMeshBinding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try await MeshTerrainDocumentAsset(document: .init(sections: [
            .init(surface: try TriangleSurface.ground(size: [12, 8], cells: 6), closure: .ground(bottomHeight: -4))
        ])).compiling()
        try initial.encodedData().write(to: directory.appendingPathComponent("ground.atmesh"))
        let file = directory.appendingPathComponent("world.aterrain")
        try TerrainManifestAsset(heightRegions: [], meshDocumentFileName: "ground.atmesh").encodedData().write(to: file)
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin()).addPlugin(Physics3DPlugin(gravity: .zero))
        try await app.build()
        let identity = MeshTerrain3DIdentity()
        let owner = app.main.spawn("Mesh Terrain") { identity; Transform(); Terrain3DSource(source: file.path, generatesCollision: true, queries: .init()) }
        try await settle(app, owner: owner)
        let root = app.main.spawn("Retained Tree") { Transform(scale: [-1, 1, 1]); MeshTerrain3DIdentity(); PhysicsBody3DComponent(shapes: [.generateBox(width: 2, height: 3, depth: 2)], mode: .static) }
        let shape = try TriangleSurface.box(minimum: [-1, -1, -1], maximum: [1, 2, 1])
        var descriptor = MeshDescriptor(name: "Trunk")
        descriptor.positions = .init(shape.positions); descriptor.indicies = shape.indices
        let mesh = Mesh.generate(from: [descriptor, descriptor], renderDevice: unsafe RenderEngine.shared.renderDevice)
        let child = app.main.spawn("Trunk and canopy") { Transform(position: [0, 0.25, 0]); Mesh3DComponent(mesh: mesh, materials: [PBRMaterial()]) }
        root.addChild(child)
        await app.main.runScheduler(.physicsSync)
        #expect(root.components[PhysicsBody3DComponent.self]?.worldBounds != nil)
        var binding = MeshTerrain3DBinding(target: identity.id, sourceID: 7, parts: [.init(nodePath: [0], part: 0)])
        let encoded = try JSONEncoder().encode(binding)
        #expect(try JSONDecoder().decode(MeshTerrain3DBinding.self, from: encoded) == binding)
        root.components[MeshTerrain3DBinding.self] = binding
        try await settleBinding(app, source: root)
        #expect(root.components[MeshTerrain3DBindingStatus.self]?.phase == .applied)
        guard root.components[MeshTerrain3DBindingStatus.self]?.phase == .applied else { return }
        #expect(root.components[PhysicsBody3DComponent.self] == nil)
        #expect(child.components[MeshTerrain3DSourceMask.self]?.parts == [.init(model: 0, part: 0)])
        #expect(try owner.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.position.y == 2.25)
        root.components[MeshTerrain3DProposedPose.self] = .init(Transform(scale: [-1, 1, 1], position: [3, 0, 0]))
        #expect(root.components[Transform.self]?.position.x == 0)
        try await settleBinding(app, source: root)
        #expect(root.components[Transform.self]?.position.x == 3)
        #expect(root.components[Transform.self]?.scale.x == -1)
        await app.main.runScheduler(.physicsSync)
        let physics = try #require(app.main.physicsWorld3D)
        let oldContact = physics.sphereCastFraction(from: [0, 5, 0], to: [0, -5, 0], radius: 0.1)
        let newContact = physics.sphereCastFraction(from: [3, 5, 0], to: [3, -5, 0], radius: 0.1)
        #expect((0.48...0.51).contains(oldContact))
        #expect((0.25...0.29).contains(newContact))
        #expect(try owner.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.position.y == 0)
        #expect(try owner.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(.init(origin: [3, 5, 0], direction: [0, -1, 0]))?.position.y == 2.25)
        binding.enabled = false
        root.components[MeshTerrain3DBinding.self] = binding
        try await settleBinding(app, source: root)
        #expect(child.components[MeshTerrain3DSourceMask.self] == nil)
        #expect(try owner.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(.init(origin: [3, 5, 0], direction: [0, -1, 0]))?.position.y == 0)
        #expect(root.components[PhysicsBody3DComponent.self] != nil)
        await app.main.runScheduler(.physicsSync)
        #expect(abs((root.components[PhysicsBody3DComponent.self]?.worldBounds?.min.x ?? 100) - 2) < 0.03)
        binding.enabled = true
        root.components[MeshTerrain3DBinding.self] = binding
        try await settleBinding(app, source: root)
        #expect(root.components[PhysicsBody3DComponent.self] == nil)
        app.main.removeEntity(owner.id, recursively: true)
        for _ in 0..<4 { await app.main.runScheduler(.preUpdate) }
        await app.main.runScheduler(.physicsSync)
        #expect(abs((root.components[PhysicsBody3DComponent.self]?.worldBounds?.min.x ?? 100) - 2) < 0.03)
        let replacementIdentity = MeshTerrain3DIdentity()
        let replacement = app.main.spawn("Replacement Terrain") {
            replacementIdentity; Transform(); Terrain3DSource(source: file.path, generatesCollision: true, queries: .init())
        }
        binding.target = replacementIdentity.id
        root.components[MeshTerrain3DBinding.self] = binding
        try await settle(app, owner: replacement)
        try await settleBinding(app, source: root)
        try #require(root.components[MeshTerrain3DBindingStatus.self]?.phase == .applied)
        root.components.remove(MeshTerrain3DBinding.self)
        try await settleBindingRemoval(app, owner: replacement)
        #expect(replacement.components[MeshTerrain3DSourceSurface.self]?.asset.document.modifiers.isEmpty == true)
        #expect(child.components[MeshTerrain3DSourceMask.self] == nil)
        #expect(root.components[PhysicsBody3DComponent.self] != nil)
        root.components[MeshTerrain3DBinding.self] = binding
        try await settleBinding(app, source: root)
        #expect(child.components[MeshTerrain3DSourceMask.self] != nil)
        app.main.removeEntity(root.id, recursively: true)
        try await settleBindingRemoval(app, owner: replacement)
        #expect(replacement.components[MeshTerrain3DSourceSurface.self]?.asset.document.modifiers.isEmpty == true)
        #expect(try replacement.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(.init(origin: [3, 5, 0], direction: [0, -1, 0]))?.position.y == 0)
    }

    private func settleBindingRemoval(_ app: AppWorlds, owner: Entity) async throws {
        for _ in 0..<2_000 {
            await app.main.runScheduler(.preUpdate)
            if owner.components[MeshTerrain3DSourceSurface.self]?.asset.document.modifiers.isEmpty == true { return }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func settleBinding(_ app: AppWorlds, source: Entity) async throws {
        for index in 0..<2_000 {
            await app.main.runScheduler(.preUpdate)
            let status = source.components[MeshTerrain3DBindingStatus.self]
            if index > 4, status?.phase == .applied, source.components[MeshTerrain3DProposedPose.self] == nil { return }
            if status?.phase == .failed || status?.phase == .orphaned { return }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func settleEdit(_ app: AppWorlds, owner: Entity, id: UUID) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            if let status = owner.components[MeshTerrain3DEditStatus.self], status.id == id, status.phase != .pending { return }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func compiledManifestPublishesGeometryAndRetainsItOnFailure() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaMeshRuntime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let surface = try TriangleSurface.ground(size: [8, 8], cells: 4)
        let asset = try await MeshTerrainDocumentAsset(document: .init(sections: [.init(surface: surface, closure: .ground(bottomHeight: -4))])).compiling()
        try asset.encodedData().write(to: directory.appendingPathComponent("ground.atmesh"))
        let file = directory.appendingPathComponent("world.aterrain")
        try TerrainManifestAsset(heightRegions: [], meshDocumentFileName: "ground.atmesh").encodedData().write(to: file)
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        var source = Terrain3DSource(source: file.path, generatesCollision: false)
        let owner = app.main.spawn("Mesh Ground") { Transform(); source }
        try await settle(app, owner: owner)
        let child = try #require(owner.children.first { $0.components[Mesh3DComponent.self] != nil })
        let initial = try #require(child.components[Mesh3DComponent.self]?.mesh.models.first?.parts.first)
        #expect(initial.indexCount == surface.indices.count)
        #expect(initial.meshDescriptor.positions.elements == surface.positions)
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("ground.atmesh"))
        source.reloadGeneration += 1; owner.components[Terrain3DSource.self] = source
        try await settle(app, owner: owner)
        #expect(owner.components[Terrain3DSourceStatus.self]?.error != nil)
        let retained = try #require(child.components[Mesh3DComponent.self]?.mesh.models.first?.parts.first)
        #expect(ObjectIdentifier(retained.vertexBuffer) == ObjectIdentifier(initial.vertexBuffer))
        owner.components.remove(Terrain3DSource.self)
        for _ in 0..<4 { await app.main.runScheduler(.preUpdate) }
        #expect(owner.children.isEmpty)
    }

    private func settle(_ app: AppWorlds, owner: Entity) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(15))
        var quiet = 0
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            let status = owner.components[Terrain3DSourceStatus.self]
            quiet = status.map { $0.isReady || $0.error != nil } == true ? quiet + 1 : 0
            if quiet >= 3 { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Mesh terrain did not settle before its bounded deadline")
    }
}

extension MeshTerrainRuntimeTests {
    @Test("Published Mesh Terrain uses source layers and a finite ground contact band", .enabled(if: TriangleMeshBoolean.isAvailable))
    func meshTerrainPublishesContactMaterials() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeshContactMaterial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = MeshTerrainBaseSection(surface: try .ground(size: [12, 12], cells: 12), closure: .ground(bottomHeight: -4))
        let rock = try TriangleSurface.box(minimum: [-1, -1, -1], maximum: [1, 2, 1])
        let source = MeshTerrainModifier(sourceID: 3, operation: .union, surface: rock, materialLayer: 21, contactWidth: 2.5)
        let asset = try await MeshTerrainDocumentAsset(document: .init(sections: [base], modifiers: [source])).compiling()
        let palette = TerrainMaterialPalette(layers: [
            .init(id: 21, name: "Rock", tint: [0.3, 0.3, 0.3, 1], roughness: 0.65, projection: .triplanar),
            .init(id: 7, name: "Soil", tint: [0.4, 0.2, 0.1, 1], roughness: 0.95)
        ], fallbackLayerID: 7)
        let manifest = directory.appendingPathComponent("world.aterrain")
        try asset.encodedData().write(to: directory.appendingPathComponent("world.atmesh"))
        try TerrainManifestAsset(materials: palette, meshDocumentFileName: "world.atmesh").encodedData().write(to: manifest)
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        let owner = app.main.spawn("Terrain") { Transform(); Terrain3DSource(source: manifest.path, generatesCollision: false, queries: .init()) }
        try await settle(app, owner: owner)
        try #require(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        let surface = try #require(owner.components[MeshTerrain3DSourceSurface.self])
        let mesh = try #require(owner.children.compactMap { $0.components[Mesh3DComponent.self] }.first)
        let material = try #require(mesh.materials.first as? PBRMaterial)
        let bindings = material.terrainBindings
        #expect(bindings != nil)
        let fields = try #require(bindings)
        let patch = try #require(surface.asset.compiled?.patches.first?.surface)
        let columns = max(1, Int(ceil(Double(patch.indices.count / 3).squareRoot())))
        #expect(fields.weights.width == columns * 2)
        #expect(try surface.queries?.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.position.y == 2)
        guard let engine = unsafe RenderEngine.shared,
            let layerIDs = engine.renderDevice.getImage(from: fields.layerIDs),
            let weights = engine.renderDevice.getImage(from: fields.weights) else { return }
        var sourceCorners = 0, groundCorners = 0, mixedCorners = 0
        for face in 0..<patch.indices.count / 3 {
            let x = (face % columns) * 2, y = (face / columns) * 2
            for corner in 0..<3 {
                let texel = ((y + (corner == 2 ? 1 : 0)) * weights.width + x + (corner == 1 ? 1 : 0)) * 4
                let position = patch.positions[Int(patch.indices[face * 3 + corner])]
                let slot = layerIDs.data[texel], weight = weights.data[texel]
                if patch.faceSources[face] == source.sourceID && position.y > 1 {
                    #expect(slot == 1 && weight == 255)
                    sourceCorners += 1
                } else if patch.faceSources[face] == 0 && abs(position.x) > 4 {
                    #expect(slot == 0 && weight == 255)
                    groundCorners += 1
                } else if patch.faceSources[face] == 0 && weights.data[texel + 1] > 0 {
                    #expect(slot != layerIDs.data[texel + 1])
                    mixedCorners += 1
                }
            }
        }
        #expect(sourceCorners > 0 && groundCorners > 0 && mixedCorners > 0)
    }

    @Test("Live bindings preserve authored join settings and portable source references", .enabled(if: TriangleMeshBoolean.isAvailable))
    func movingBoundModelRetainsJoinMetadata() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeshJoinMetadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelFile = directory.appendingPathComponent("rock.vox")
        let voxel = VOXModel(sizeX: 1, sizeY: 1, sizeZ: 1, voxels: [.init(x: 0, y: 0, z: 0, colorIndex: 1)])
        try VOXWriter().encode(model: voxel, palette: .fallback).write(to: modelFile)
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        let sourceIdentity = MeshTerrain3DIdentity(), targetIdentity = MeshTerrain3DIdentity()
        let root = app.main.spawn("Imported rock") { Transform(); Model3DSource(source: modelFile.path); sourceIdentity }
        var captured: MeshTerrainCapturedSource?
        let loadDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < loadDeadline {
            await app.main.runScheduler(.preUpdate)
            captured = try? MeshTerrainSourceCapture.capture(root)
            if captured != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let operand = try #require(captured).surface
        let bounds = try #require(operand.bounds)
        let y = -(bounds.minimum.y + bounds.maximum.y) * 0.5
        let pose = Transform(position: [-2, y, 0])
        root.components[Transform.self] = pose
        let rounding = MeshTerrainRounding(radius: 1, maximumDeviation: 0.08)
        let joined = MeshTerrainModifier(sourceID: 1, operation: .union, surface: operand, transform: pose.matrix,
            entityID: sourceIdentity.id, sourcePath: "@res://rock.vox", materialLayer: 17, contactWidth: 2, rounding: rounding)
        let base = MeshTerrainBaseSection(surface: try TriangleSurface.ground(size: [12, 12], cells: 6), closure: .ground(bottomHeight: -8))
        let asset = try await MeshTerrainDocumentAsset(document: .init(sections: [base], modifiers: [joined])).compiling()
        let manifest = directory.appendingPathComponent("world.aterrain")
        try asset.encodedData().write(to: directory.appendingPathComponent("ground.atmesh"))
        let palette = TerrainMaterialPalette(layers: [.init(id: 17, name: "Rock")], fallbackLayerID: 17, interiorLayerID: 17)
        try TerrainManifestAsset(heightRegions: [], materials: palette, meshDocumentFileName: "ground.atmesh").encodedData().write(to: manifest)
        let owner = app.main.spawn("Ground") { Transform(); Terrain3DSource(source: manifest.path, generatesCollision: false); targetIdentity }
        root.components[MeshTerrain3DBinding.self] = .init(target: targetIdentity.id, modifier: joined.id, sourceID: joined.sourceID, contactWidth: 2)
        for x: Float in [-2, 2] {
            if x == 2 { root.components[MeshTerrain3DProposedPose.self] = .init(Transform(position: [x, y, 0])) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                await app.main.runScheduler(.preUpdate)
                if root.components[Transform.self]?.position.x == x, root.components[MeshTerrain3DProposedPose.self] == nil,
                    root.components[MeshTerrain3DBindingStatus.self]?.phase == .applied { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(root.components[MeshTerrain3DBindingStatus.self]?.phase == .applied)
            let saved = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.asset.document.modifiers.first)
            #expect(saved.sourcePath == "@res://rock.vox")
            #expect(saved.materialLayer == 17)
            #expect(saved.rounding == rounding)
            #expect(saved.contactWidth == 2)
            #expect(saved.transform.origin.x == x)
        }
    }

    @Test("A moving join refills its old footprint and retains distant instance buffers", .enabled(if: TriangleMeshBoolean.isAvailable))
    func movedJoinRedistributesResidentPopulation() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeshPopulation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let voxel = VOXModel(sizeX: 1, sizeY: 1, sizeZ: 1, voxels: [.init(x: 0, y: 0, z: 0, colorIndex: 1)])
        try VOXWriter().encode(model: voxel, palette: .fallback).write(to: directory.appendingPathComponent("plant.vox"))
        let ground = try TriangleSurface.ground(size: [64, 64], cells: 16)
        let rock = try TriangleSurface.box(minimum: [-1, -1, -1], maximum: [1, 2, 1])
        var document = MeshTerrainDocument(sections: [.init(surface: ground, closure: .ground(bottomHeight: -8))],
            modifiers: [.init(sourceID: 1, operation: .union, surface: rock, transform: .init(translation: [-2, 0, 0]))])
        let ruleID = try #require(UUID(uuidString: "94AD0068-C541-482F-B0C9-DC34E050353B"))
        let rule = MeshTerrainPopulationRule(id: ruleID, prototypeID: 1, seed: 73, bounds: .init(minimum: [-5, -0.1, -5], maximum: [5, 0.1, 5]),
            density: 2, spacing: 0.4, sourceExclusionDistance: 0.8)
        let manual = MeshTerrainPlacement(id: 901, prototypeID: 1, transform: .init(translation: [20, 0, 4]))
        let initial = try await MeshTerrainDocumentAsset(document: document, populationRules: [rule], manualPlacements: [manual]).compiling()
        let manifest = directory.appendingPathComponent("world.aterrain")
        try initial.encodedData().write(to: directory.appendingPathComponent("ground.atmesh"))
        try TerrainManifestAsset(heightRegions: [], meshPrototypes: [.init(id: 1, assetPath: "plant.vox")], meshDocumentFileName: "ground.atmesh")
            .encodedData().write(to: manifest)
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        let owner = app.main.spawn("Ground") { Transform(); Terrain3DSource(source: manifest.path, generatesCollision: false, queries: .init()) }
        let source = app.main.spawn("Joined rock") { Transform(position: [-2, 0, 0]) }
        try await settle(app, owner: owner)
        func batches() -> [Mesh3DInstancesComponent] { owner.children.compactMap { $0.components[Mesh3DInstancesComponent.self] } }
        let far = try #require(batches().first { $0.instances.contains { $0.id == manual.id } })
        let buffer = try #require(far.mesh.models.first?.parts.first?.vertexBuffer)
        func checkPopulation(moved: Bool) throws {
            let surface = try #require(owner.components[MeshTerrain3DSourceSurface.self])
            let records = try #require(surface.asset.compiled?.placements)
            let resident = Set(batches().flatMap(\.instances).map(\.id))
            #expect(resident == Set(records.map(\.id)))
            #expect(resident.contains(manual.id))
            func containsPlant(at x: Float) -> Bool {
                records.contains { $0.ownership == .generated && abs($0.transform.origin.x - x) < 1 && abs($0.transform.origin.z) < 1 }
            }
            #expect(containsPlant(at: -2) == moved)
            #expect(containsPlant(at: 2) != moved)
            #expect(try surface.queries?.raycast(.init(origin: [-2, 5, 0], direction: [0, -1, 0]))?.position.y == (moved ? 0 : 2))
        }
        try checkPopulation(moved: false)
        document.modifiers[0].transform = .init(translation: [2, 0, 0])
        let candidate = MeshTerrainDocumentAsset(document: document, populationRules: [rule], manualPlacements: [manual])
        let edit = MeshTerrain3DEdit(expectedInputKey: try initial.authoringKey(), candidate: candidate,
            sourceTransforms: [.init(entity: source.id, pose: .init(position: [2, 0, 0]))])
        owner.components[MeshTerrain3DEdit.self] = edit
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            let moved = source.components[Transform.self]?.position.x == 2
            try checkPopulation(moved: moved)
            if owner.components[MeshTerrain3DEditStatus.self]?.id == edit.id,
                owner.components[MeshTerrain3DEditStatus.self]?.phase != .pending { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(owner.components[MeshTerrain3DEditStatus.self]?.phase == .applied)
        #expect(source.components[Transform.self]?.position.x == 2)
        #expect(batches().allSatisfy { $0.mesh.models.first?.parts.first?.vertexBuffer === buffer })
    }
}
