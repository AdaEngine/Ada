import AdaAnimation
import AdaEngine
@_spi(Internal) import AdaRender
import Testing

@testable import AdaScene

@Suite
struct AnimationLOD3DTests {
    @Test
    func movingTheCameraAndModelTogetherDoesNotBecomeOffscreenAtTheWorldOrigin() throws {
        let pose = SkeletalJointPose()
        let rig = try SkeletalRig(nodes: [.init(parentIndex: nil, restPose: pose, restMatrix: pose.matrix)])
        let track = try SkeletalAnimationTrack(nodeIndex: 0, path: .translation, interpolation: .linear, times: [0, 1], values: [.zero, [1, 0, 0, 0]])
        var player = try SkeletalAnimationPlayer(rig: rig, clips: [.init(name: "Move", tracks: [track])])
        try player.play("Move", transitionDuration: 0)
        var state = AnimationLOD3DState()
        let settings = AnimationLOD3DSettings(radius: 0.1)
        var camera = Camera()
        // The legacy cached field may be stale; observers must use the authoritative camera view.
        camera.computedData.viewMatrix = .identity
        camera.computedData.projectionMatrix = .identity
        for origin: Float in [0, 30, -30] {
            camera.viewMatrix = Transform3D(translation: [-origin, 0, 0])
            let observer = AnimationLOD3DObserver(camera: camera)
            for _ in 0..<10 {
                state.advance(player: &player, delta: 1 / 60, settings: settings, transform: Transform3D(translation: [origin, 0, 0.5]), observers: [observer])
                #expect(state.interval == 0)
                #expect(abs(Double(player.poses[0].translation.x) - player.time) < 0.0001)
            }
        }
    }

    @Test
    func clocksAdvanceWithoutSamplingAndVisiblePosesInterpolate() throws {
        let pose = SkeletalJointPose()
        let rig = try SkeletalRig(nodes: [.init(parentIndex: nil, restPose: pose, restMatrix: pose.matrix)])
        let track = try SkeletalAnimationTrack(nodeIndex: 0, path: .translation, interpolation: .linear, times: [0, 1], values: [.zero, [1, 0, 0, 0]])
        var player = try SkeletalAnimationPlayer(rig: rig, clips: [.init(name: "Move", tracks: [track])])
        try player.play("Move", transitionDuration: 0)
        var state = AnimationLOD3DState()
        var settings = AnimationLOD3DSettings(radius: 0.01, screenThresholds: [0.5], sampleRates: [0, 10])
        let observer = AnimationLOD3DObserver(view: .identity, projection: .identity, frustum: .init(viewProjection: .identity))
        func tick(_ delta: Double, observers: [AnimationLOD3DObserver] = [observer]) {
            state.advance(player: &player, delta: delta, settings: settings, transform: Transform3D(translation: [0, 0, 0.5]), observers: observers)
        }
        tick(0)
        tick(0.05)
        #expect(abs(player.time - 0.05) < 0.0001)
        #expect(player.poses[0].translation.x == 0)
        tick(0.05)
        tick(0.05)
        #expect(abs(player.time - 0.15) < 0.0001)
        #expect(abs(player.poses[0].translation.x - 0.05) < 0.0001)
        tick(0, observers: [])
        let generation = player.poseGeneration
        tick(0.05, observers: [])
        #expect(player.poseGeneration == generation)
        #expect(abs(player.time - 0.2) < 0.0001)
        player.seek(to: 0.8)
        tick(0, observers: [])
        #expect(abs(player.poses[0].translation.x - 0.8) < 0.0001)
        settings.screenThresholds = [0.001]
        tick(0)
        #expect(state.level == 0)
        #expect(abs(player.poses[0].translation.x - 0.8) < 0.0001)
        player.repeats = false
        tick(0.3)
        #expect(player.time == 1 && !player.isPlaying)
        #expect(player.poses[0].translation.x == 1)
    }
}
