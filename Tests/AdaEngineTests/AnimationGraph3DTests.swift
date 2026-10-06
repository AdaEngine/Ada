@_spi(Internal) import AdaApp
import AdaECS
import AdaTransform
import AdaUtils
import Math
import Testing

@testable import AdaAnimation
@testable import AdaScene

@MainActor
@Suite
struct AnimationGraph3DTests {
    @Test func modelSystemDeliversMarkersEvenWhenPoseSamplingIsOffscreen() async throws {
        let pose = SkeletalJointPose()
        let rig = try SkeletalRig(nodes: [.init(parentIndex: nil, restPose: pose, restMatrix: pose.matrix)])
        let track = try SkeletalAnimationTrack(nodeIndex: 0, path: .translation, interpolation: .linear, times: [0, 1], values: [.zero, [1, 0, 0, 0]])
        var player = try SkeletalAnimationPlayer(rig: rig, clips: [.init(name: "Walk", tracks: [track])])
        try player.play(AnimationGraph(root: "Walk", nodes: [.init(id: "Walk", clip: "Walk", events: [.init(time: 0.2, name: "Footstep")])]), transitionDuration: 0)
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        var component = ModelAnimation3DComponent(player: player)
        component.evaluationLOD = .init(offscreenRate: 1)
        let root = app.main.spawn("Actor") {
            Transform()
            component
        }
        let node = app.main.spawn("Animated node") {
            Transform()
            ModelNode3DComponent(modelRoot: root.id, nodeIndex: 0)
        }
        root.addChild(node)
        await app.main.runScheduler(.postUpdate, deltaTime: 0.1)
        await app.main.runScheduler(.postUpdate, deltaTime: 0.1)
        await app.main.runScheduler(.postUpdate, deltaTime: 0.1)
        let events = Events<ModelAnimation3DEvent>(from: app.main)
        events.update(from: app.main)
        #expect(events.currentEvents.count == 1)
        #expect(events.currentEvents.first?.modelRoot == root.id)
        #expect(events.currentEvents.first?.animation.marker.name == "Footstep")
        #expect(root.components[ModelAnimation3DComponent.self]?.player.drainGraphEvents().isEmpty == true)
        #expect(abs((node.components[Transform.self]?.position.x ?? 0) - 0.1) < 0.00001, "The offscreen pose stays at its first sample while markers advance")
    }
}
