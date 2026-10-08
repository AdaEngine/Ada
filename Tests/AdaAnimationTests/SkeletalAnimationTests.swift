import AdaAnimation
import Math
import Testing

@Suite
struct SkeletalAnimationTests {
    @Test
    func samplesLinearAndStepWithoutLosingEndpoints() throws {
        let linear = try track(path: .translation, interpolation: .linear, values: [.zero, [2, 0, 0, 0]])
        #expect(linear.sample(at: -1) == .zero)
        #expect(linear.sample(at: 0.25).x == 0.5)
        #expect(linear.sample(at: 2).x == 2)
        let step = try track(path: .translation, interpolation: .step, values: [.zero, [2, 0, 0, 0]])
        #expect(step.sample(at: 0.99).x == 0)
        #expect(step.sample(at: 1).x == 2)
    }

    @Test
    func cubicTangentsAreScaledByKeyframeSpan() throws {
        let cubic = try SkeletalAnimationTrack(
            nodeIndex: 0,
            path: .translation,
            interpolation: .cubicSpline,
            times: [0, 2],
            values: [.zero, .zero, [1, 0, 0, 0], .zero, .zero, .zero]
        )
        #expect(abs(cubic.sample(at: 1).x - 0.25) < 0.00001)
    }

    @Test
    func quaternionLinearUsesShortestPathAndCubicNormalizesValues() throws {
        let linear = try track(path: .rotation, interpolation: .linear, values: [[0, 0, 0, 1], [0, 0, 0, -1]])
        #expect(abs(linear.sample(at: 0.5).w - 1) < 0.00001)
        let cubic = try track(
            path: .rotation,
            interpolation: .cubicSpline,
            values: [.zero, [0, 0, 0, 1], [2, 0, 0, 0], .zero, [0, 0, 1, 0], .zero]
        )
        let value = cubic.sample(at: 0.5)
        #expect(abs(value.dot(value) - 1) < 0.00001)
    }

    @Test
    func evaluatesParentsBeforeChildrenRegardlessOfArrayOrder() throws {
        let pose = SkeletalJointPose(translation: [0, 1, 0])
        let matrix = Transform3D(translation: [3, 0, 0])
        let rig = try SkeletalRig(nodes: [
            .init(parentIndex: 1, restPose: pose, restMatrix: pose.matrix),
            .init(parentIndex: nil, restPose: nil, restMatrix: matrix)
        ])
        let player = try SkeletalAnimationPlayer(rig: rig, clips: [])
        #expect(player.globalTransforms[0].origin == Vector3(3, 1, 0))
        #expect(player.globalTransforms[1] == matrix)
    }

    @Test
    func playersHaveIndependentPosesAndPauseSeekAndRepeat() throws {
        var first = try player()
        var second = first
        try first.play("Move", transitionDuration: 0)
        try second.play("Move", transitionDuration: 0)
        first.advance(by: 0.25)
        second.advance(by: 0.75)
        #expect(first.poses[0].translation.x == 0.5)
        #expect(second.poses[0].translation.x == 1.5)
        first.isPlaying = false
        first.advance(by: 1)
        #expect(first.time == 0.25)
        first.seek(to: 1.25)
        #expect(first.poses[0].translation.x == 0.5)
        first.isPlaying = true
        first.speed = -1
        first.advance(by: 0.5)
        #expect(first.poses[0].translation.x == 1.5)
    }

    @Test
    func nonRepeatingPlaybackHoldsTheFinalPose() throws {
        var player = try player()
        player.repeats = false
        try player.play("Move", transitionDuration: 0)
        player.advance(by: 2)
        #expect(!player.isPlaying)
        #expect(player.time == 1)
        #expect(player.poses[0].translation.x == 2)
    }

    @Test
    func phaseMatchedPlaybackPreservesAndCompletesTheFade() throws {
        var player = try player()
        try player.play("Move", transitionDuration: 0)
        player.seek(to: 0.25)
        let source = player.poses[0].translation.x
        try player.play("Move", transitionDuration: 0.2, startTime: 0.75)
        #expect(player.time == 0.75)
        #expect(player.poses[0].translation.x == source)
        player.advance(by: 0.1)
        #expect(abs(player.poses[0].translation.x - 1.1) < 0.00001)
        player.advance(by: 0.1)
        #expect(abs(player.poses[0].translation.x - 1.9) < 0.00001)
        try player.play("Move", transitionDuration: 0, startTime: .nan)
        #expect(player.time == 0)
        #expect(player.poses[0].translation == .zero)
    }

    @Test
    func shortOneShotClipFinishesItsTransitionBeforeStopping() throws {
        let constant = try SkeletalAnimationTrack(nodeIndex: 0, path: .translation, interpolation: .linear, times: [0], values: [[2, 0, 0, 0]])
        var player = try SkeletalAnimationPlayer(rig: rig(), clips: [.init(name: "Pose", tracks: [constant])])
        player.repeats = false
        try player.play("Pose", transitionDuration: 0.2)
        player.advance(by: 0.1)
        #expect(player.isPlaying)
        #expect(player.poses[0].translation.x == 1)
        player.advance(by: 0.1)
        #expect(!player.isPlaying)
        #expect(player.poses[0].translation.x == 2)
    }

    @Test
    func transitionsBlendFromTheCurrentPose() throws {
        let rig = try rig()
        let first = SkeletalAnimationClip(name: "First", tracks: [try track(path: .translation, interpolation: .linear, values: [.zero, [2, 0, 0, 0]])])
        let second = SkeletalAnimationClip(name: "Second", tracks: [try track(path: .translation, interpolation: .linear, values: [[10, 0, 0, 0], [10, 0, 0, 0]])])
        var player = try SkeletalAnimationPlayer(rig: rig, clips: [first, second])
        try player.play("First", transitionDuration: 0)
        player.seek(to: 0.5)
        try player.play("Second", transitionDuration: 1)
        #expect(player.poses[0].translation.x == 1)
        player.advance(by: 0.5)
        #expect(player.poses[0].translation.x == 5.5)
        player.advance(by: 0.5)
        #expect(player.poses[0].translation.x == 10)
    }

    @Test
    func rejectsCyclesMissingNodesAndMatrixAnimationTargets() throws {
        #expect(throws: SkeletalAnimationError.invalidHierarchy) {
            try SkeletalRig(nodes: [.init(parentIndex: 0, restPose: nil, restMatrix: .identity)])
        }
        let track = try track(path: .translation, interpolation: .linear, values: [.zero, .zero])
        let rig = try SkeletalRig(nodes: [.init(parentIndex: nil, restPose: nil, restMatrix: .identity)])
        #expect(throws: SkeletalAnimationError.invalidTrack) {
            try SkeletalAnimationPlayer(rig: rig, clips: [.init(name: "Move", tracks: [track])])
        }
    }

    @Test
    func invalidClockInputsKeepTheLastValidPose() throws {
        var player = try player()
        try player.play("Move", transitionDuration: 0)
        player.advance(by: 0.25)
        player.advance(by: .nan)
        player.seek(to: .infinity)
        #expect(player.time == 0.25)
        #expect(player.poses[0].translation.x == 0.5)
        #expect(throws: SkeletalAnimationError.unknownClip("Missing")) { try player.play("Missing") }
    }

    private func track(path: SkeletalAnimationTrack.Path, interpolation: SkeletalAnimationTrack.Interpolation, values: [Vector4]) throws -> SkeletalAnimationTrack {
        try SkeletalAnimationTrack(nodeIndex: 0, path: path, interpolation: interpolation, times: [0, 1], values: values)
    }

    private func rig() throws -> SkeletalRig {
        try SkeletalRig(nodes: [.init(parentIndex: nil, restPose: SkeletalJointPose(), restMatrix: .identity)])
    }

    private func player() throws -> SkeletalAnimationPlayer {
        try SkeletalAnimationPlayer(rig: rig(), clips: [
            .init(name: "Move", tracks: [try track(path: .translation, interpolation: .linear, values: [.zero, [2, 0, 0, 0]])])
        ])
    }
}
