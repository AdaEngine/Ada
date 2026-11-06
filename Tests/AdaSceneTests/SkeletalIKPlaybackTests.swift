import AdaAnimation
import AdaApp
import AdaAssets
import AdaECS
@testable import AdaScene
import AdaTransform
import Math
import Testing

@MainActor
@Suite(.serialized)
struct SkeletalIKPlaybackTests {
    @Test(arguments: [false, true])
    func pausedMovingTargetsPublishTheSamePoseToNodesAndSkin(withLOD: Bool) async throws {
        let world = World()
        let app = AppWorlds(main: world)
        app.addPlugin(TransformPlugin()).addPlugin(Model3DPlugin())
        let fixture = try makeInstance(world: world, namespace: "first", withLOD: withLOD)
        try await app.build()
        for target: Vector3 in [[12, 2, 0], [10, 4, 0], [8, 2, 0]] {
            fixture.marker.components[Transform.self]?.position = target
            await world.runScheduler(.postUpdate, deltaTime: 0.01)
            let animation = try #require(fixture.root.components[ModelAnimation3DComponent.self])
            let endpoint = animation.player.globalTransforms[2].origin
            #expect((endpoint - (target - Vector3(10, 0, 0)) / 2).length < 0.0002)
            let palette = try #require(fixture.mesh.components[SkinnedMesh3DComponent.self])
            #expect((palette.matrices[0].origin - endpoint).length < 0.0001)
            let node = try #require(fixture.end.components[GlobalTransform.self])
            #expect((node.matrix.origin - target).length < 0.0003)
            #expect(animation.player.time == 0)
            var player = animation.player
            #expect(player.drainGraphEvents().isEmpty)
            if withLOD { #expect(animation.lodState.target == animation.player.basePoses) }
        }
        world.removeEntity(fixture.marker.id)
        await world.runScheduler(.postUpdate, deltaTime: 0)
        let animation = try #require(fixture.root.components[ModelAnimation3DComponent.self])
        #expect(animation.player.modifierDiagnostics.first?.status == .invalidTarget)
        #expect(animation.player.poses == animation.player.basePoses)
    }

    @Test
    func targetsUnderAnotherAnimatedRigAreRejectedAndInstancesRemainIndependent() async throws {
        let world = World()
        let app = AppWorlds(main: world)
        app.addPlugin(TransformPlugin()).addPlugin(Model3DPlugin())
        let first = try makeInstance(world: world, namespace: "first", withLOD: false)
        let second = try makeInstance(world: world, namespace: "second", withLOD: false)
        second.marker.components[Transform.self]?.position = [10, 4, 0]
        try await app.build()
        await world.runScheduler(.postUpdate, deltaTime: 0)
        let firstPose = try #require(first.root.components[ModelAnimation3DComponent.self]?.player.poses)
        let secondPose = try #require(second.root.components[ModelAnimation3DComponent.self]?.player.poses)
        #expect(firstPose != secondPose)
        second.root.addChild(first.marker)
        await world.runScheduler(.postUpdate, deltaTime: 0)
        let rejected = try #require(first.root.components[ModelAnimation3DComponent.self])
        #expect(rejected.player.modifierDiagnostics.first?.status == .invalidTarget)
        #expect(rejected.player.poses == rejected.player.basePoses)
        #expect(second.root.components[ModelAnimation3DComponent.self]?.player.poses == secondPose)
    }

    private func makeInstance(world: World, namespace: String, withLOD: Bool) throws -> (root: Entity, end: Entity, mesh: Entity, marker: Entity) {
        let poses = [SkeletalJointPose(), SkeletalJointPose(translation: [1, 0, 0]),
                     SkeletalJointPose(translation: [1, 0, 0]), SkeletalJointPose()]
        let parents: [Int?] = [nil, 0, 1, nil]
        let rig = try SkeletalRig(nodes: poses.indices.map {
            .init(parentIndex: parents[$0], restPose: poses[$0], restMatrix: poses[$0].matrix)
        })
        var player = try SkeletalAnimationPlayer(rig: rig, clips: [])
        try player.setPoseModifiers([.init(id: "arm", kind: .twoBone, joints: ["node-0", "node-1", "node-2"], target: [2, 0, 0])],
                                    binding: AnimationRigBinding(rig: rig, sourceAsset: "Robot.glb"))
        var animation = ModelAnimation3DComponent(player: player)
        animation.modifierNamespace = namespace
        animation.modifierBindings = ["arm": .init(target: .init(entity: "target"))]
        if withLOD { animation.evaluationLOD = AnimationLOD3DSettings(offscreenRate: 1) }
        let root = world.spawn("Model") { Transform(scale: Vector3(2), position: [10, 0, 0]); animation }
        let first = world.spawn("Root") { Transform(); ModelNode3DComponent(modelRoot: root.id, nodeIndex: 0) }
        let middle = world.spawn("Middle") { Transform(position: [1, 0, 0]); ModelNode3DComponent(modelRoot: root.id, nodeIndex: 1) }
        let end = world.spawn("End") { Transform(position: [1, 0, 0]); ModelNode3DComponent(modelRoot: root.id, nodeIndex: 2) }
        root.addChild(first); first.addChild(middle); middle.addChild(end)
        let mesh = world.spawn("Mesh") {
            Transform()
            SkinnedMesh3DComponent(modelRoot: root.id, meshNodeIndex: 3,
                                  skin: .init(name: nil, joints: [2], skeletonRootIndex: nil, inverseBindMatrices: [.identity]))
        }
        root.addChild(mesh)
        let marker = world.spawn("Target") { Transform(position: [12, 2, 0]); AnimationSceneIdentity3D(namespace: namespace, id: "target") }
        return (root, end, mesh, marker)
    }
}
