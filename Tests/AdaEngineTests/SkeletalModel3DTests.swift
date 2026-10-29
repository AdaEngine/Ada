@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Testing

@MainActor
@Suite
struct SkeletalModel3DTests {
    @Test("paused models retain authored node edits while another instance resumes its pose")
    func pausedNodeEditsAndIndependentPoseUpdates() async throws {
        let app = try await makeApp()
        let model = try loadModel("TwoBoneRibbon")
        let first = model.instantiate(in: app.main), second = model.instantiate(in: app.main)
        await app.main.runScheduler(.preUpdate)
        await app.main.runScheduler(.postUpdate, deltaTime: 0)
        let firstMesh = try #require(skinnedMeshes(first).first)
        let secondMesh = try #require(skinnedMeshes(second).first)
        let initialGeneration = try #require(secondMesh.components[SkinnedMesh3DComponent.self]).poseGeneration
        app.main.clearTrackers()
        secondMesh.components[Transform.self] = Transform(position: [3, 4, 5])
        await app.main.runScheduler(.postUpdate, deltaTime: 0)
        #expect(FilterQuery<ModelAnimation3DComponent, Changed<ModelAnimation3DComponent>>(from: app.main).first == nil)
        #expect(secondMesh.components[Transform.self]?.position == Vector3(3, 4, 5))
        #expect(secondMesh.components[SkinnedMesh3DComponent.self]?.poseGeneration == initialGeneration)
        var animation = try #require(first.components[ModelAnimation3DComponent.self])
        try animation.player.play("Bend", transitionDuration: 0)
        animation.player.seek(to: 0.5)
        first.components[ModelAnimation3DComponent.self] = animation
        await app.main.runScheduler(.postUpdate, deltaTime: 0)
        #expect(firstMesh.components[SkinnedMesh3DComponent.self]?.matrices != secondMesh.components[SkinnedMesh3DComponent.self]?.matrices)
        #expect(secondMesh.components[Transform.self]?.position == Vector3(3, 4, 5))
        #expect(secondMesh.components[SkinnedMesh3DComponent.self]?.poseGeneration == initialGeneration)
    }

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
        await app.main.runScheduler(.preUpdate, deltaTime: 0)
        // The scheduler supplies DeltaTime itself; sample the sought pose without wall-clock advancement.
        await app.main.runScheduler(.postUpdate, deltaTime: 0)
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
    func independentSkinPalettesShareBatchesAndReuseFrameBuffers() async throws {
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
        for _ in 0 ..< 4 {
            await renderWorld.runScheduler(.extract)
            let items = try VisibleMesh3D.capture(from: renderWorld).items
            #expect(items.count == 1)
            let sources = try #require(renderWorld.getResource(ExtractedMesh3DSources.self)).meshes
            let firstSource = try #require(sources.first { $0.entity == firstMesh.id })
            let secondSource = try #require(sources.first { $0.entity == secondMesh.id })
            let firstBuffer = try #require(firstSource.skinningBuffer)
            let secondBuffer = try #require(secondSource.skinningBuffer)
            #expect(ObjectIdentifier(firstBuffer) == ObjectIdentifier(secondBuffer))
            #expect(firstSource.skinningOffset != secondSource.skinningOffset)
            #expect(items.allSatisfy { $0.batchRange?.count == 2 })
            #expect(items.allSatisfy { $0.castShadows })
            buffers.append(ObjectIdentifier(firstBuffer))
        }
        #expect(buffers[0] == buffers[3])
        #expect(buffers[0] != buffers[1])
    }

    @Test("packed palettes preserve exact independent poses and their history after reordering")
    func packedPoseContentsAndReorderedHistory() async throws {
        let app = try await makeApp()
        let device = unsafe RenderEngine.shared.renderDevice
        var uniforms = Skinning3DUniforms()
        let a = app.main.spawn().id, b = app.main.spawn().id, overflow = app.main.spawn().id
        let first = [Transform3D](repeating: Transform3D(translation: [1, 2, 3]), count: Skinning3DUniforms.maximumJoints / 2)
        let second = [Transform3D](repeating: Transform3D(translation: [-3, 4, 5]), count: Skinning3DUniforms.maximumJoints / 2)
        uniforms.beginFrame(device: device)
        let firstBufferValue = uniforms.writePacked(first, for: a, device: device, revision: nil)

        let firstBuffer = try #require(firstBufferValue)
        let secondBufferValue = uniforms.writePacked(second, for: b, device: device, revision: nil)

        let secondBuffer = try #require(secondBufferValue)
        let overflowBufferValue = uniforms.writePacked([.identity], for: overflow, device: device, revision: nil)

        let overflowBuffer = try #require(overflowBufferValue)
        uniforms.finishPackedWrites()
        #expect(ObjectIdentifier(firstBuffer) == ObjectIdentifier(secondBuffer))
        #expect(ObjectIdentifier(firstBuffer) != ObjectIdentifier(overflowBuffer))
        #expect(uniforms.packedOffset(for: a) == 0 && uniforms.packedOffset(for: b) == Skinning3DUniforms.maximumJoints / 2)
        let initial = try await firstBuffer.readData()
        #expect(readMatrices(initial) == first + second)
        uniforms.beginFrame(device: device)
        _ = uniforms.writePacked(first, for: b, device: device, revision: nil)
        let changedValue = uniforms.writePacked(second, for: a, device: device, revision: nil)

        let changed = try #require(changedValue)
        uniforms.finishPackedWrites()
        #expect(uniforms.packedOffset(for: b) == 0 && uniforms.packedOffset(for: a) == Skinning3DUniforms.maximumJoints / 2)
        #expect(readMatrices(try await changed.readData()) == first + second)
        let previous = try #require(uniforms.previousBuffer(for: a))
        #expect(readMatrices(try await previous.readData()) == second + first)
    }

    private func readMatrices(_ data: Data) -> [Transform3D] {
        data.withUnsafeBytes { bytes in
            (0 ..< data.count / MemoryLayout<Transform3D>.stride).map {
                bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Transform3D>.stride, as: Transform3D.self)
            }
        }
    }

    @Test
    func skinnedShadowPipelineDoesNotAllocateAnUnusedFallbackVertexSlot() async throws {
        _ = try await makeApp()
        let model = try loadModel("TestHumanoid")
        let part = try #require(model.meshes.first?.models.first?.parts.first)
        var pipeline = DirectionalShadow3DPipeline().configurate(with: part.vertexDescriptor)
        #expect(pipeline.vertexDescriptor.layouts.enumerated().allSatisfy { index, layout in
            layout.stride == 0 || pipeline.vertexDescriptor.attributes.contains { $0.format != .invalid && $0.bufferIndex == index }
        })
        #expect(pipeline.vertexDescriptor.layouts[3].stride == MemoryLayout<Flat3DInstanceData>.stride)
        var staticMesh = MeshDescriptor(name: "Static")
        staticMesh.positions = MeshBuffer([Vector3.zero])
        var fallback = DirectionalShadow3DPipeline().configurate(with: staticMesh.getMeshVertexBufferDescriptor())
        #expect(fallback.vertexDescriptor.layouts[4].stride == MemoryLayout<Flat3DDefaultVertexData>.stride)
    }

    @Test
    func staticBatchesHaveEnoughFallbackVerticesForEveryInstance() async throws {
        let app = try await makeApp()
        let device = unsafe RenderEngine.shared.renderDevice
        let mesh = Mesh.generateCube(renderDevice: device)
        let material = PBRMaterial()
        for _ in 0 ..< 4 {
            app.main.spawn {
                Mesh3DComponent(mesh: mesh, materials: [material])
                Transform()
            }
        }
        await app.main.runScheduler(.preUpdate)
        let renderWorld = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
        renderWorld.insertResource(MainWorld(world: app.main))
        await renderWorld.runScheduler(.extract)
        let visible = try VisibleMesh3D.capture(from: renderWorld)
        let items = visible.items
        #expect(items.count == 1)
        #expect(items[0].batchRange?.count == 4)
        let defaults = try #require(visible.buffers.defaults)
        #expect(defaults.count >= 4)
        #expect(defaults.elements.allSatisfy { $0.jointIndices.x == -1 })
    }

    @Test
    func paletteCancelsTheMeshNodeTransformAndPreservesBindPose() throws {
        let rig = try SkeletalRig(nodes: [
            .init(parentIndex: nil, restPose: SkeletalJointPose(translation: [5, 0, 0]), restMatrix: Transform3D(translation: [5, 0, 0])),
            .init(parentIndex: nil, restPose: SkeletalJointPose(translation: [0, 1, 0]), restMatrix: Transform3D(translation: [0, 1, 0])),
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
        (0 ..< 4).allSatisfy { column in
            (0 ..< 4).allSatisfy { row in abs(matrix[column, row] - Transform3D.identity[column, row]) < 0.0001 }
        }
    }
}
