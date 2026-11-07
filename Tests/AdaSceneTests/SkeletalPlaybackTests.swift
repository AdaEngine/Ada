import AdaAnimation
import AdaApp
import AdaAssets
import AdaECS
@_spi(Internal) @testable import AdaRender
@testable import AdaScene
import AdaTransform
import Foundation
import Math
import Testing

@MainActor
@Suite(.serialized)
struct SkeletalPlaybackTests {
    @Test func failedLibraryReplacementPreservesTheLiveModelAndSkin() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader())
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let modelURL = tests.appendingPathComponent("AdaEngineTests/Fixtures/SkeletalGardenAssets/GardenRobot.glb")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("BadLibrary-\(UUID()).animlib")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let incompatible = AnimationLibrary(binding: .init(sourceAsset: "Robot.glb", nodes: []), clips: [.init(name: "Invalid rig", duration: 1)])
        try incompatible.encodedData().write(to: temporary)
        let world = World()
        let app = AppWorlds(main: world)
        app.addPlugin(TransformPlugin()).addPlugin(Model3DPlugin())
        let owner = world.spawn("Owner") { Transform(); Model3DSource(source: modelURL.path, animation: "Walk", autoplay: true) }
        try await app.build()
        for _ in 0..<200 where owner.components[Model3DSourceState.self]?.rootEntityID == nil {
            await world.runScheduler(.preUpdate, deltaTime: 0.01)
            await world.runScheduler(.postUpdate, deltaTime: 0.01)
            try await Task.sleep(for: .milliseconds(10))
        }
        let originalRoot = try #require(owner.components[Model3DSourceState.self]?.rootEntityID)
        let originalChildren = owner.children.map(\.id)
        owner.components[Model3DSource.self]?.animationLibraries = [temporary.path]
        for _ in 0..<200 where owner.components[Model3DSourceState.self]?.error == nil {
            await world.runScheduler(.preUpdate, deltaTime: 0.01)
            await world.runScheduler(.postUpdate, deltaTime: 0.01)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(owner.components[Model3DSourceState.self]?.error != nil)
        #expect(owner.components[Model3DSourceState.self]?.rootEntityID == originalRoot)
        #expect(owner.children.map(\.id) == originalChildren)
        #expect(world.getEntityByID(originalRoot)?.components[ModelAnimation3DComponent.self] != nil)
    }

    @Test
    func sceneReplacementReservesExclusiveWorldAccess() {
        let system = SceneNavigationSystem(world: World())
        #expect(system.queries.access.hasExclusiveWorldAccess)
    }

    @Test
    func copyingAPausedScenePreservesItsCurrentSkinPose() async throws {
        let scene = try makePlaybackScene()
        let app = AppWorlds(main: scene.world)
        app.addPlugin(TransformPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        await scene.world.runScheduler(.postUpdate, deltaTime: 0.25)
        let sourceOwner = try #require(scene.world.getEntityByName("Owner"))
        sourceOwner.components[ModelAnimationPlayback3DComponent.self]?.isPlaying = false
        await scene.world.runScheduler(.postUpdate, deltaTime: 0)
        let sourceMesh = try #require(scene.world.getEntityByName("Mesh"))
        let sourceSkin = try #require(sourceMesh.components[SkinnedMesh3DComponent.self])
        #expect(sourceSkin.matrices[0].origin.x == 0.5)

        let destination = World()
        SceneNavigator(world: destination).installInitialScene(scene, make: { try makePlaybackScene() })
        let mesh = try #require(destination.getEntityByName("Mesh"))
        let skin = try #require(mesh.components[SkinnedMesh3DComponent.self])
        #expect(skin.matrices == sourceSkin.matrices)
        #expect(skin.paletteID != sourceSkin.paletteID)
        let root = try #require(destination.getEntityByName("Model"))
        #expect(root.components[ModelAnimation3DComponent.self]?.player.isPlaying == false)
        #expect(root.components[ModelAnimation3DComponent.self]?.player.time == 0.25)
    }

    @Test(arguments: [false, true])
    func importedRobotAutoplayAdvancesJoints(throughSceneNavigation: Bool) async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader())
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = tests.appendingPathComponent("AdaEngineTests/Fixtures/SkeletalGardenAssets/GardenRobot.glb")
        let model = try #require(AssetsManager.loadSync(ModelAsset3D.self, at: url.path).asset)
        let app = AppWorlds(main: World())
        app.addPlugin(TransformPlugin()).addPlugin(Model3DPlugin())
        let sourceWorld = throughSceneNavigation ? World() : app.main
        let owner = sourceWorld.spawn("Owner") { Transform() }
        try Model3DSource(animation: "Walk", autoplay: true).instantiate(model, in: sourceWorld, under: owner)
        if throughSceneNavigation {
            let navigator = SceneNavigator(world: app.main)
            navigator.installInitialScene(Scene(from: sourceWorld), make: { Scene() })
        }
        let root = try #require(app.main.getEntityByName(model.assetName))
        let initial = try #require(root.components[ModelAnimation3DComponent.self])
        #expect(initial.player.isPlaying)
        #expect(initial.player.clipIndex != nil)
        let joint = try #require(app.main.getEntityByName("UpperLeg.L"))
        let initialTransform = joint.components[Transform.self]
        try await app.build()
        await app.main.runScheduler(.postUpdate, deltaTime: 0.25)
        let current = try #require(root.components[ModelAnimation3DComponent.self])
        #expect(current.player.time == 0.25)
        #expect(current.player.poses != initial.player.poses)
        #expect(joint.components[Transform.self] != initialTransform)
    }

    @Test(arguments: [false, true])
    func scheduledPlaybackAdvancesNodesAndSkinPalette(throughSceneNavigation: Bool) async throws {
        let world = World()
        let app = AppWorlds(main: world)
        app.addPlugin(TransformPlugin()).addPlugin(ScenePlugin())
        try await app.build()
        world.spawn("Persistent host entity") { Transform() }
        let scene = try makePlaybackScene()
        let navigator = try #require(world.getResource(SceneNavigator.self))
        if throughSceneNavigation {
            navigator.installInitialScene(scene, make: { try makePlaybackScene() })
        }
        let runtime = throughSceneNavigation ? world : scene.world
        if !throughSceneNavigation {
            let direct = AppWorlds(main: runtime)
            direct.addPlugin(TransformPlugin()).addPlugin(Model3DPlugin())
            try await direct.build()
        }
        let root = try #require(runtime.getEntityByName("Model"))
        let joint = try #require(runtime.getEntityByName("Joint"))
        let mesh = try #require(runtime.getEntityByName("Mesh"))
        let owner = try #require(runtime.getEntityByName("Owner"))
        #expect(owner.components[Model3DSourceState.self]?.rootEntityID == root.id)
        #expect(joint.components[ModelNode3DComponent.self]?.modelRoot == root.id)
        #expect(mesh.components[SkinnedMesh3DComponent.self]?.modelRoot == root.id)
        if throughSceneNavigation {
            let sourceMesh = try #require(scene.world.getEntityByName("Mesh"))
            #expect(mesh.components[SkinnedMesh3DComponent.self]?.paletteID != sourceMesh.components[SkinnedMesh3DComponent.self]?.paletteID)
        }
        await runtime.runScheduler(.postUpdate, deltaTime: 0.25)
        let animation = try #require(root.components[ModelAnimation3DComponent.self])
        #expect(animation.player.isPlaying)
        #expect(animation.player.time == 0.25)
        #expect(joint.components[Transform.self]?.position.x == 0.5)
        #expect(mesh.components[SkinnedMesh3DComponent.self]?.matrices[0].origin.x == 0.5)
        await runtime.runScheduler(.postUpdate, deltaTime: 0.25)
        #expect(root.components[ModelAnimation3DComponent.self]?.player.time == 0.5)
        #expect(joint.components[Transform.self]?.position.x == 1)
        #expect(mesh.components[SkinnedMesh3DComponent.self]?.matrices[0].origin.x == 1)
        owner.components[ModelAnimationPlayback3DComponent.self]?.isPlaying = false
        await runtime.runScheduler(.postUpdate, deltaTime: 0.25)
        #expect(root.components[ModelAnimation3DComponent.self]?.player.time == 0.5)

        if throughSceneNavigation {
            let sourceRoot = try #require(scene.world.getEntityByName("Model"))
            #expect(sourceRoot.components[ModelAnimation3DComponent.self]?.player.time == 0)
            let reload = Task { try await navigator.reloadScene() }
            for _ in 0..<100 where world.getEntityByID(root.id) != nil {
                await world.runScheduler(.postUpdate, deltaTime: 0)
                try await Task.sleep(for: .milliseconds(10))
            }
            try await reload.value
            #expect(world.getEntityByID(root.id) == nil)
            await world.runScheduler(.postUpdate, deltaTime: 0.25)
            let reloadedMesh = try #require(world.getEntityByName("Mesh"))
            let reloadedRoot = try #require(world.getEntityByName("Model"))
            #expect(reloadedMesh.components[SkinnedMesh3DComponent.self]?.modelRoot == reloadedRoot.id)
            #expect(reloadedMesh.components[SkinnedMesh3DComponent.self]?.matrices[0].origin.x == 0.5)
            #expect(world.getEntityByName("Persistent host entity") != nil)
        }
    }

    private func makePlaybackScene() throws -> Scene {
        let scene = Scene(name: "Animated")
        let world = scene.world
        let rig = try SkeletalRig(nodes: [
            .init(parentIndex: nil, restPose: .init(), restMatrix: .identity),
            .init(parentIndex: 0, restPose: .init(), restMatrix: .identity),
        ])
        let track = try SkeletalAnimationTrack(nodeIndex: 1, path: .translation, interpolation: .linear,
                                               times: [0, 1], values: [.zero, [2, 0, 0, 0]])
        let player = try SkeletalAnimationPlayer(rig: rig, clips: [.init(name: "Move", tracks: [track])])
        let root = world.spawn("Model") {
            ModelAnimation3DComponent(player: player)
            Transform()
        }
        var controls = ModelAnimationPlayback3DComponent()
        controls.clip = "Move"
        controls.transitionDuration = 0
        let owner = world.spawn("Owner") {
            controls
            Model3DSource()
            Model3DSourceState(reference: .init(), rootEntityID: root.id)
        }
        let joint = world.spawn("Joint") {
            ModelNode3DComponent(modelRoot: root.id, nodeIndex: 1)
            Transform()
        }
        let mesh = world.spawn("Mesh") {
            SkinnedMesh3DComponent(modelRoot: root.id, meshNodeIndex: 0,
                                   skin: .init(name: nil, joints: [1], skeletonRootIndex: nil, inverseBindMatrices: [.identity]))
        }
        owner.addChild(root)
        root.addChild(joint)
        root.addChild(mesh)
        return scene
    }
}
