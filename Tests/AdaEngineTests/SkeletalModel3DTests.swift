@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Testing

@MainActor
@Suite
struct SkeletalModel3DTests {
    @Test
    func importsAndInstantiatesIndependentPlayersAndVertexInfluences() async throws {
        let app = try await makeApp()
        let model = try loadModel("TwoBoneRibbon")
        #expect(model.skins[0].joints.count == 2)
        #expect(model.animationClips.map(\.name) == ["Bend"])
        let part = try #require(model.meshes.first?.models.first?.parts.first)
        #expect(part.vertexDescriptor.attributes.containsAttribute(by: MeshDescriptor.jointIndices.id.name))
        #expect(part.vertexDescriptor.attributes.containsAttribute(by: MeshDescriptor.jointWeights.id.name))
        let first = model.instantiate(in: app.main)
        let second = model.instantiate(in: app.main)
        var firstAnimation = try #require(first.components[ModelAnimation3DComponent.self])
        try firstAnimation.player.play("Bend", transitionDuration: 0)
        firstAnimation.player.seek(to: 0.5)
        first.components[ModelAnimation3DComponent.self] = firstAnimation
        await app.main.runScheduler(.preUpdate)
        app.main.insertResource(DeltaTime(deltaTime: 0))
        await app.main.runScheduler(.postUpdate)
        let firstMesh = try #require(skinnedMeshes(first).first)
        let secondMesh = try #require(skinnedMeshes(second).first)
        let firstSkin = try #require(firstMesh.components[SkinnedMesh3DComponent.self])
        let secondSkin = try #require(secondMesh.components[SkinnedMesh3DComponent.self])
        #expect(firstSkin.matrices != secondSkin.matrices)
        #expect(secondSkin.matrices.allSatisfy { nearIdentity($0) })
        #expect(firstSkin.modelRoot == first.id)
        #expect(secondSkin.modelRoot == second.id)
    }

    @Test
    func independentSkinPalettesSplitBatchesAndReuseFrameBuffers() async throws {
        let app = try await makeApp()
        let model = try loadModel("TestHumanoid")
        let first = model.instantiate(in: app.main)
        let second = model.instantiate(in: app.main)
        await app.main.runScheduler(.preUpdate)
        let firstMesh = try #require(skinnedMeshes(first).first)
        let secondMesh = try #require(skinnedMeshes(second).first)
        let renderWorld = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
        renderWorld.insertResource(MainWorld(world: app.main))
        var buffers: [ObjectIdentifier] = []
        for _ in 0..<4 {
            await renderWorld.runScheduler(.extract)
            let items = try #require(renderWorld.getResource(RenderItems<Opaque3DRenderItem>.self)).items
            #expect(items.count == 2)
            let firstBuffer = try #require(items.first { $0.entity == firstMesh.id }?.skinningBuffer)
            let secondBuffer = try #require(items.first { $0.entity == secondMesh.id }?.skinningBuffer)
            #expect(ObjectIdentifier(firstBuffer) != ObjectIdentifier(secondBuffer))
            #expect(items.allSatisfy { $0.batchRange?.count == 1 })
            #expect(items.allSatisfy { $0.castShadows })
            buffers.append(ObjectIdentifier(firstBuffer))
        }
        #expect(buffers[0] == buffers[3])
        #expect(buffers[0] != buffers[1])
    }

    @Test
    func paletteCancelsTheMeshNodeTransformAndPreservesBindPose() throws {
        let rig = try SkeletalRig(nodes: [
            .init(parentIndex: nil, restPose: SkeletalJointPose(translation: [5, 0, 0]), restMatrix: Transform3D(translation: [5, 0, 0])),
            .init(parentIndex: nil, restPose: SkeletalJointPose(translation: [0, 1, 0]), restMatrix: Transform3D(translation: [0, 1, 0]))
        ])
        let player = try SkeletalAnimationPlayer(rig: rig, clips: [])
        let skin = GLTFImportResult.Skin(name: nil, joints: [1], skeletonRootIndex: nil, inverseBindMatrices: [.identity])
        var binding = SkinnedMesh3DComponent(modelRoot: Entity.ID(), meshNodeIndex: 0, skin: skin)
        binding.updateMatrices(using: player)
        #expect(binding.matrices[0].origin == Vector3(-5, 1, 0))
    }

    private func makeApp() async throws -> AppWorlds {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader())
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin())
            .addPlugin(TransformPlugin())
            .addPlugin(RenderWorldPlugin())
            .addPlugin(Model3DPlugin())
        try await app.build()
        return app
    }

    private func loadModel(_ name: String) throws -> ModelAsset3D {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = tests.appendingPathComponent("AdaAssetsTests/Fixtures/\(name).glb")
        return try #require(AssetsManager.loadSync(ModelAsset3D.self, at: url.path).asset)
    }

    private func skinnedMeshes(_ root: Entity) -> [Entity] {
        var pending = root.children
        var meshes: [Entity] = []
        while let entity = pending.popLast() {
            if entity.components[SkinnedMesh3DComponent.self] != nil { meshes.append(entity) }
            pending.append(contentsOf: entity.children)
        }
        return meshes
    }

    private func nearIdentity(_ matrix: Transform3D) -> Bool {
        (0..<4).allSatisfy { column in
            (0..<4).allSatisfy { row in abs(matrix[column, row] - Transform3D.identity[column, row]) < 0.0001 }
        }
    }
}
