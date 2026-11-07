@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
@testable import AdaScene
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    private func materialSource(_ palette: TerrainMaterialPalette, in directory: URL, physics: Bool = false) async throws -> (AppWorlds, Entity) {
        var terrain = Terrain3D(resolution: 129, size: 128)
        for z in 0..<terrain.resolution {
            for x in 0..<terrain.resolution { terrain.heights[z * terrain.resolution + x] = Float(x) / 8 }
        }
        let file = try await save(terrain, in: directory)
        let old = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        let manifest = TerrainManifestAsset(
            spacing: old.spacing,
            originX: old.originX,
            originZ: old.originZ,
            heightRegions: old.heightRegions,
            materials: palette
        )
        try manifest.encodedData().write(to: file)
        let app = try await makeApp(physics: physics)
        let owner = app.main.spawn("Biome terrain") {
            Transform(position: [40, 20, -10])
            Terrain3DSource(source: file.path, generatesCollision: physics, maximumLOD: 0, streamingRadius: nil)
        }
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        return (app, owner)
    }

    private func materialRows(_ owner: Entity, tile: TerrainTileCoordinate) throws -> ([Vector4], [Vector4]) {
        let state = try #require(owner.components[TerrainSourceState.self])
        let descriptor = try #require(state.tiles[tile]?.descriptor)
        let ids = try #require(descriptor[MeshDescriptor.custom("terrainMaterialLayerIDs", type: Vector4.self)])
        let weights = try #require(descriptor[MeshDescriptor.custom("terrainMaterialWeights", type: Vector4.self)])
        #expect(ids.count == descriptor.positions.count && weights.count == descriptor.positions.count)
        return (ids.elements, weights.elements)
    }

    private func materialWeights(ids: Vector4, weights: Vector4) -> [Int: Float] {
        var result: [Int: Float] = [:]
        for (id, weight) in zip([ids.x, ids.y, ids.z, ids.w], [weights.x, weights.y, weights.z, weights.w]) where weight > 0 {
            result[Int(id)] = weight
        }
        return result
    }

    @Test("Source geometry resolves local-height rules across tile borders independently of layer display order", arguments: [false, true])
    func terrainSourceMaterialHeightRules(reversed: Bool) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var layers = [TerrainLayerReference(id: 7, name: "Grass"), TerrainLayerReference(id: 12, name: "Rock")]
        if reversed { layers.reverse() }
        let palette = TerrainMaterialPalette(
            layers: layers,
            fallbackLayerID: 7,
            rules: [
                .init(layerID: 7, height: .init(minimum: -100, maximum: 0, transition: 2)),
                .init(layerID: 12, height: .init(minimum: 2, maximum: 100, transition: 2)),
            ]
        )
        let (app, owner) = try await materialSource(palette, in: directory)
        defer { withExtendedLifetime(app) {} }
        let (leftIDs, leftWeights) = try materialRows(owner, tile: .init(x: 0, z: 0))
        let (rightIDs, rightWeights) = try materialRows(owner, tile: .init(x: 1, z: 0))
        #expect(materialWeights(ids: leftIDs[0], weights: leftWeights[0]) == [7: 1])
        let middle = materialWeights(ids: leftIDs[8], weights: leftWeights[8])
        #expect(abs((middle[7] ?? 0) - 0.5) < 0.0001)
        #expect(abs((middle[12] ?? 0) - 0.5) < 0.0001)
        #expect(leftIDs[64] == rightIDs[0] && leftWeights[64] == rightWeights[0])
        #expect(materialWeights(ids: rightIDs[0], weights: rightWeights[0]) == [12: 1])
    }

    @Test("Rule normalization retains at most four strongest stable IDs and falls back when all rules are disabled")
    func terrainSourceMaterialPruningAndFallback() async throws {
        for enabled in [true, false] {
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let layers = (10..<16).map { TerrainLayerReference(id: UInt16($0), name: "Layer \($0)") }
            let rules = (10..<16).map { TerrainMaterialRule(layerID: UInt16($0), enabled: enabled, weight: Float($0 - 9)) }
            let (app, owner) = try await materialSource(.init(layers: layers, fallbackLayerID: 10, rules: rules), in: directory)
            defer { withExtendedLifetime(app) {} }
            let (ids, weights) = try materialRows(owner, tile: .init(x: 0, z: 0))
            let resolved = materialWeights(ids: ids[0], weights: weights[0])
            if enabled {
                #expect(Set(resolved.keys) == [12, 13, 14, 15])
                #expect(abs(resolved.values.reduce(0, +) - 1) < 0.0001)
                #expect(abs((resolved[15] ?? 0) - 6.0 / 18) < 0.0001)
            } else {
                #expect(resolved == [10: 1])
            }
        }
    }

    @Test("Planar terrain has neutral curvature at true boundaries, corners and shared tile halos")
    func terrainSourceMaterialCurvatureEdges() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let palette = TerrainMaterialPalette(
            layers: [.init(id: 7, name: "Plane"), .init(id: 12, name: "Curved")],
            fallbackLayerID: 12,
            rules: [.init(layerID: 7, curvature: .init(minimum: -0.0001, maximum: 0.0001))]
        )
        let (app, owner) = try await materialSource(palette, in: directory)
        defer { withExtendedLifetime(app) {} }
        let (leftIDs, leftWeights) = try materialRows(owner, tile: .init(x: 0, z: 0))
        let (rightIDs, rightWeights) = try materialRows(owner, tile: .init(x: 1, z: 0))
        for index in [0, 32, 65 * 32, 65 * 32 + 32, 64, 4_224] {
            #expect(materialWeights(ids: leftIDs[index], weights: leftWeights[index]) == [7: 1])
            #expect(materialWeights(ids: rightIDs[index], weights: rightWeights[index]) == [7: 1])
        }
        #expect(leftIDs[64] == rightIDs[0] && leftWeights[64] == rightWeights[0])
    }

    @Test("Changing only render LOD retains canonical material buffers and performs no material evaluations")
    func terrainSourceMaterialFieldsSurviveLOD() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let palette = TerrainMaterialPalette(
            layers: [.init(id: 7, name: "Grass")],
            fallbackLayerID: 7,
            rules: [.init(layerID: 7, noiseStrength: 1)]
        )
        let (app, owner) = try await materialSource(palette, in: directory)
        let initial = try #require(owner.components[TerrainSourceState.self])
        #expect(initial.materialSampleEvaluationCount > 0)
        let coordinate = TerrainTileCoordinate(x: 0, z: 0)
        let initialTile = try #require(initial.tiles[coordinate])
        let ids = try #require(initialTile.descriptor[TerrainSourceMaterials.layerIDs])
        let weights = try #require(initialTile.descriptor[TerrainSourceMaterials.weights])
        let idsIdentity = ObjectIdentifier(ids.buffer), weightsIdentity = ObjectIdentifier(weights.buffer)
        var source = try #require(owner.components[Terrain3DSource.self])
        source.maximumLOD = 6
        source.lodDistance = 32
        owner.components[Terrain3DSource.self] = source
        let camera = app.main.spawn("Biome LOD camera") {
            Transform(position: [40, 24, -10]); Camera()
        }
        var previousLevel = initialTile.selection.level
        for distance: Float in [256, 10_000] {
            camera.components[Transform.self] = Transform(position: [40 + distance, 24, -10])
            await settle(app)
            let state = try #require(owner.components[TerrainSourceState.self])
            let tile = try #require(state.tiles[coordinate])
            #expect(tile.selection.level > previousLevel)
            #expect(state.materialSampleEvaluationCount == 0)
            let nextIDs = try #require(tile.descriptor[TerrainSourceMaterials.layerIDs])
            let nextWeights = try #require(tile.descriptor[TerrainSourceMaterials.weights])
            #expect(ObjectIdentifier(nextIDs.buffer) == idsIdentity)
            #expect(ObjectIdentifier(nextWeights.buffer) == weightsIdentity)
            previousLevel = tile.selection.level
        }
    }

    @Test("Published palette fields survive color changes and are removed when the palette is removed")
    func terrainSourceMaterialPublicationLifecycle() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let palette = TerrainMaterialPalette(layers: [.init(id: 7, name: "Grass")], fallbackLayerID: 7)
        let (app, owner) = try await materialSource(palette, in: directory)
        let coordinate = TerrainTileCoordinate(x: 0, z: 0)
        func material() throws -> PBRMaterial {
            let state = try #require(owner.components[TerrainSourceState.self])
            let tile = try #require(state.tiles[coordinate])
            let entity = try #require(app.main.getEntityByID(tile.entity))
            return try #require(entity.components[Mesh3DComponent.self]?.materials.first as? PBRMaterial)
        }
        let initial = try material()
        let fields = try #require(initial.terrainBindings)
        var source = try #require(owner.components[Terrain3DSource.self])
        source.color = [0.3, 0.6, 0.9, 1]
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        let recolored = try material()
        #expect(recolored === initial)
        #expect(recolored.terrainBindings === fields)
        #expect(recolored.baseColorFactor == source.color)

        let path = URL(fileURLWithPath: source.source)
        let manifest = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: path.path)
        let plain = TerrainManifestAsset(
            spacing: manifest.spacing, originX: manifest.originX, originZ: manifest.originZ, heightRegions: manifest.heightRegions
        )
        try plain.encodedData().write(to: path)
        source.reloadGeneration &+= 1
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        let replaced = try material()
        #expect(replaced.terrainBindings == nil)
        #expect(replaced.baseColorFactor == source.color)
        #expect(replaced !== initial)
    }

    @Test("Missing material map warnings survive physical readiness synchronization")
    func terrainSourceMaterialWarningsSurvivePhysics() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let palette = TerrainMaterialPalette(layers: [.init(id: 7, name: "Missing", albedoPath: "absent.png")], fallbackLayerID: 7)
        let (app, owner) = try await materialSource(palette, in: directory, physics: true)
        let initial = try #require(owner.components[Terrain3DSourceStatus.self])
        try #require(initial.isReady)
        try #require(initial.warnings.count == 1 && initial.warnings[0].contains("absent.png"))
        app.main.spawn("Collision interest") {
            Transform(position: [40, 50, -10])
            PhysicsBody3DComponent(shapes: [.generateSphere(radius: 0.5)], mass: 1, mode: .dynamic)
        }
        await app.main.runScheduler(.physicsSync)
        let synchronized = try #require(owner.components[Terrain3DSourceStatus.self])
        #expect(synchronized.isReady)
        #expect(synchronized.warnings == initial.warnings)
    }

    @Test("Material-field uploads publish finite grid coordinates or reject unsupported spacing", arguments: [Float(1), Float(1e-40)])
    func terrainSourceMaterialGridFinite(spacing: Float) async throws {
        let app = try await makeApp()
        defer { withExtendedLifetime(app) {} }
        let engine = try #require(unsafe RenderEngine.shared)
        let storage = try TerrainHeightStorage(spacing: spacing)
        try storage.allocateRegion(at: .init(x: 0, z: 0))
        let coordinate = TerrainTileCoordinate(x: 0, z: 0)
        let snapshot = try #require(storage.snapshot(of: coordinate))
        let palette = TerrainMaterialPalette(layers: [.init(id: 7, name: "Finite fields")], fallbackLayerID: 7)
        let canonical = try TerrainSourceMaterials.prepare(snapshot, storage: storage, resolver: TerrainMaterialResolver(palette)).descriptor
        let texture = Texture2D(descriptor: .init(
            width: 1, height: 1, pixelFormat: .rgba8, textureUsage: [.read], textureType: .texture2DArray, image: Image(width: 1, height: 1, color: .white)
        ))
        let maps = TerrainMaterialTextureArrays(sourceID: UUID(), albedo: texture, normal: texture, orm: texture)
        do {
            let material = try TerrainSourceMaterialUpload.make(
                descriptor: canonical, coordinate: coordinate, storage: storage, palette: palette, maps: maps, color: .one, device: engine.renderDevice
            )
            let buffer = try #require(material.terrainBindings?.parameters)
            let data = try await buffer.readData()
            let grid = unsafe data.withUnsafeBytes { bytes in
                (0..<4).map { unsafe bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.stride, as: Float.self) }
            }
            let finiteGrid = grid.allSatisfy { $0.isFinite }
            #expect(finiteGrid)
        } catch TerrainSourceError.resourceLoadingFailed(let message) {
            #expect(spacing < Float.leastNormalMagnitude && message.contains("spacing"))
        }
    }
}
