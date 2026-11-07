@_spi(Internal) @testable import AdaApp
@testable import AdaCorePipelines
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Terrain prototypes retain every active node, primitive and material in imported transform order")
    func terrainPrototypePreservesImportedStructure() async throws {
        let app = try await makeApp()
        let device = unsafe RenderEngine.shared.renderDevice
        let cube = Mesh.generateCube(renderDevice: device)
        let original = try #require(cube.models.first?.parts.first)
        var other = original
        other.materialIndex = 1
        let compound = Mesh(models: [Mesh.Model(name: "Two surfaces", parts: [original, other])])
        let materials = [PBRMaterial(), PBRMaterial()]
        let rootPose = Transform3D(translation: [2, 1, 0], rotation: .identity, scale: [-1, 2, 1])
        let firstPose = Transform3D(translation: [3, 0, 0])
        let secondPose = Transform3D(translation: [0, 4, 0])
        let model = ModelAsset3D(
            nodes: [
                .init(name: "Model", transform: rootPose, meshIndex: nil, children: [1, 2]),
                .init(name: "Crown", transform: firstPose, meshIndex: 0, children: []),
                .init(name: "Trunk", transform: .identity, meshIndex: 1, children: [], restPose: .init(translation: secondPose.origin)),
                .init(name: "Other scene", transform: .identity, meshIndex: 0, children: []),
            ],
            meshes: [compound, cube],
            materials: materials,
            scenes: [[0], [3]],
            defaultScene: 0
        )
        let prototype = try TerrainMeshPrototype(model: model)
        #expect(prototype.parts.map(\.nodeIndex) == [1, 2])
        #expect(prototype.parts.map(\.transform) == [rootPose * firstPose, rootPose * secondPose])
        #expect(prototype.materials.count == 2)
        #expect(prototype.drawPartCount == 3)
        #expect(prototype.materials[0] === materials[0] && prototype.materials[1] === materials[1])
        #expect(prototype.parts[0].mesh.models[0].parts.count == 2)
        #expect(prototype.parts[0].mesh.models[0].parts[1].materialIndex == 1)
        #expect(prototype.parts[0].mesh.models[0].parts[0].vertexBuffer === original.vertexBuffer)
        let placements = [
            Mesh3DInstance(id: 12, transform: Transform3D(translation: [4, 0, 0], rotation: Quat(axis: [0, 1, 0], angle: .pi / 2), scale: [2, 1, 1])),
            Mesh3DInstance(id: 13, transform: Transform3D(translation: [-4, 0, 0]), color: [0.4, 0.5, 0.6, 1]),
        ]
        let batches = try prototype.makeBatches(instances: placements)
        #expect(batches.count == 2)
        let parent = app.main.spawn("Terrain") { Transform(position: [10, 3, 5]) }
        for batch in batches {
            let child = app.main.spawn {
                Transform(); batch
            }
            parent.addChild(child)
        }
        await app.main.runScheduler(.postUpdate)
        let render = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
        render.insertResource(MainWorld(world: app.main))
        await render.runScheduler(.extract)
        let sources = try #require(render.getResource(ExtractedMesh3DSources.self)).meshes
        #expect(sources.count == 2)
        #expect(app.main.getEntities().count == 3)
        for index in batches.indices {
            #expect(batches[index].instances.map(\.id) == placements.map(\.id))
            #expect(batches[index].instances.map(\.color) == placements.map(\.color))
            for placement in placements.indices {
                #expect(batches[index].instances[placement].transform == placements[placement].transform * prototype.parts[index].transform)
            }
        }
        var lists = VisibleMesh3DLists(), uniforms = PBR3DUniforms()
        uniforms.beginFrame()
        lists.prepare(
            sources: sources,
            view: parent.id,
            pass: -1,
            viewMatrix: .identity,
            projection: .identity,
            cullingProjection: .identity,
            settings: .init(frustumCulling: false, lod: false, distanceCulling: false),
            device: device,
            materials: &uniforms
        )
        #expect(lists.count(view: parent.id, pass: -1).visibleMeshes == 4)
        #expect(lists.count(view: parent.id, pass: -1).triangles == 72)
        #expect(lists.items(view: parent.id, pass: -1).count == 2)
        let alternate = try TerrainMeshPrototype(model: model, scene: 1)
        #expect(alternate.parts.map(\.nodeIndex) == [3])
    }

    @Test("Prototype preparation rejects cyclic, duplicate, missing and noninvertible active nodes")
    func terrainPrototypeRejectsMalformedModels() async throws {
        _ = try await makeApp()
        let cube = Mesh.generateCube(renderDevice: unsafe RenderEngine.shared.renderDevice)
        func model(_ nodes: [ModelAsset3D.Node], scenes: [[Int]] = [[0]]) -> ModelAsset3D {
            ModelAsset3D(nodes: nodes, meshes: [cube], materials: [PBRMaterial()], scenes: scenes, defaultScene: 0)
        }
        let cycle = model([.init(name: nil, transform: .identity, meshIndex: 0, children: [0])])
        #expect(throws: TerrainMeshPrototypeError.invalidHierarchy) { try TerrainMeshPrototype(model: cycle) }
        let duplicate = model([.init(name: nil, transform: .identity, meshIndex: 0, children: [])], scenes: [[0, 0]])
        #expect(throws: TerrainMeshPrototypeError.invalidHierarchy) { try TerrainMeshPrototype(model: duplicate) }
        let missing = model([.init(name: nil, transform: .identity, meshIndex: 3, children: [])])
        #expect(throws: TerrainMeshPrototypeError.invalidHierarchy) { try TerrainMeshPrototype(model: missing) }
        let singular = model([.init(name: nil, transform: Transform3D(scale: [0, 1, 1]), meshIndex: 0, children: [])])
        #expect(throws: TerrainMeshPrototypeError.invalidTransform) { try TerrainMeshPrototype(model: singular) }
        let skinned = model([.init(name: nil, transform: .identity, meshIndex: 0, children: [], skinIndex: 0)])
        #expect(throws: TerrainMeshPrototypeError.unsupportedDeformation) { try TerrainMeshPrototype(model: skinned) }
        let empty = model([.init(name: nil, transform: .identity, meshIndex: nil, children: [])])
        #expect(throws: TerrainMeshPrototypeError.emptyModel) { try TerrainMeshPrototype(model: empty) }
        #expect(throws: TerrainMeshPrototypeError.invalidScene) { try TerrainMeshPrototype(model: empty, scene: 2) }
        var nonfinite = Transform3D.identity
        nonfinite.w.x = .nan
        let invalidPose = model([.init(name: nil, transform: nonfinite, meshIndex: 0, children: [])])
        #expect(throws: TerrainMeshPrototypeError.invalidTransform) { try TerrainMeshPrototype(model: invalidPose) }
        let many = model(Array(repeating: .init(name: nil, transform: .identity, meshIndex: nil, children: []), count: 4_097))
        #expect(throws: TerrainMeshPrototypeError.budgetExceeded) { try TerrainMeshPrototype(model: many) }
    }

    @Test("Prototype batch expansion preflights bytes and rejects ambiguous or nonfinite placements")
    func terrainPrototypeBoundsExpansion() async throws {
        _ = try await makeApp()
        let cube = Mesh.generateCube(renderDevice: unsafe RenderEngine.shared.renderDevice)
        let model = ModelAsset3D(
            nodes: [.init(name: nil, transform: .identity, meshIndex: 0, children: [])],
            meshes: [cube],
            materials: [PBRMaterial()],
            scenes: [[0]],
            defaultScene: 0
        )
        let prototype = try TerrainMeshPrototype(model: model)
        #expect(throws: TerrainMeshPrototypeError.budgetExceeded) {
            try prototype.makeBatches(instances: [Mesh3DInstance(id: 1)], maximumExpandedBytes: 1)
        }
        #expect(throws: TerrainMeshPrototypeError.invalidPlacement) {
            try prototype.makeBatches(instances: [Mesh3DInstance(id: 1), Mesh3DInstance(id: 1)])
        }
        #expect(throws: TerrainMeshPrototypeError.invalidPlacement) {
            try prototype.makeBatches(instances: [Mesh3DInstance(id: 2, color: [.nan, 1, 1, 1])])
        }
        #expect(try prototype.makeBatches(instances: []).isEmpty)
        let part = try #require(cube.models.first?.parts.first)
        let manyParts = Mesh(models: [Mesh.Model(name: "Many draw parts", parts: Array(repeating: part, count: 64))])
        let heavy = ModelAsset3D(nodes: model.nodes, meshes: [manyParts], materials: model.materials, scenes: model.scenes, defaultScene: 0)
        let costly = try TerrainMeshPrototype(model: heavy)
        let placements = (0..<4_097).map { Mesh3DInstance(id: UInt64($0)) }
        #expect(throws: TerrainMeshPrototypeError.budgetExceeded) { try costly.makeBatches(instances: placements) }
    }
}
