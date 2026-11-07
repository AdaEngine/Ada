import AdaAnimation
import Math
import Testing

@Suite
struct SkeletalIKTests {
    @Test
    func twoBoneReachesTargetWithoutChangingBaseOrRestPose() throws {
        var player = try chain()
        let base = player.poses
        let binding = AnimationRigBinding(rig: player.rig, sourceAsset: "Robot.glb")
        try player.setPoseModifiers([
            .init(id: "arm", kind: .twoBone, joints: ["node-0", "node-1", "node-2"], target: [1, 1, 0], pole: [0, 0, 1])
        ], binding: binding)
        #expect((player.globalTransforms[2].origin - Vector3(1, 1, 0)).length < 0.0001)
        #expect(player.basePoses == base)
        #expect(player.rig.nodes[1].restPose == base[1])
        let final = player.poses
        for _ in 0..<50 { player.finalizePoseModifiers() }
        #expect(player.poses == final)
        #expect(player.poses.map(\.translation) == base.map(\.translation))
        #expect(player.poses.map(\.scale) == base.map(\.scale))
        #expect(player.poses[2].rotation == base[2].rotation)
    }

    @Test
    func fabrikBendsStraightChainToInteriorTargetAndPreservesLengths() throws {
        var player = try chain()
        let binding = AnimationRigBinding(rig: player.rig, sourceAsset: "Robot.glb")
        try player.setPoseModifiers([
            .init(id: "tail", kind: .fabrik, joints: ["node-0", "node-1", "node-2"], target: [1, 0, 0], iterations: 64)
        ], binding: binding)
        #expect((player.globalTransforms[2].origin - Vector3(1, 0, 0)).length < 0.0002)
        #expect(player.modifierDiagnostics.first?.status == .solved)
        for index in 1...2 {
            #expect(abs((player.globalTransforms[index].origin - player.globalTransforms[index - 1].origin).length - 1) < 0.0001)
        }
        let result = player.poses
        player.sampleCurrentPose()
        #expect(player.poses == result)
        #expect(player.globalTransforms[0].origin == .zero)
    }

    @Test(arguments: [AnimationPoseModifier.Kind.twoBone, .fabrik])
    func unreachableOuterAndInnerTargetsDoNotStretch(kind: AnimationPoseModifier.Kind) throws {
        for target: Vector3 in [[8, 0, 0], [0, 0, 0]] {
            var player = try chain(lengths: [2, 1])
            let binding = AnimationRigBinding(rig: player.rig, sourceAsset: "Robot.glb")
            try player.setPoseModifiers([.init(id: "ik", kind: kind, joints: ["node-0", "node-1", "node-2"], target: target)], binding: binding)
            #expect(player.modifierDiagnostics.first?.status == .unreachable)
            #expect((player.modifierDiagnostics.first?.reachError ?? 0) > 0.99)
            #expect(abs((player.globalTransforms[1].origin - player.globalTransforms[0].origin).length - 2) < 0.0001)
            #expect(abs((player.globalTransforms[2].origin - player.globalTransforms[1].origin).length - 1) < 0.0001)
        }
    }

    @Test
    func influenceIsAppliedOnceAndZeroRestoresBase() throws {
        var player = try chain()
        let binding = AnimationRigBinding(rig: player.rig, sourceAsset: "Robot.glb")
        var modifier = AnimationPoseModifier(id: "ik", kind: .twoBone, joints: ["node-0", "node-1", "node-2"], target: [0, 2, 0], influence: 0.5)
        try player.setPoseModifiers([modifier], binding: binding)
        #expect((player.globalTransforms[2].origin - Vector3(sqrt(2), sqrt(2), 0)).length < 0.0001)
        #expect((player.modifierDiagnostics.first?.solverError ?? 1) < 0.0001)
        #expect((player.modifierDiagnostics.first?.reachError ?? 0) > 1)
        modifier.influence = 0
        try player.setPoseModifiers([modifier], binding: binding)
        #expect(player.poses == player.basePoses)
        modifier.enabled = false
        try player.setPoseModifiers([modifier], binding: binding)
        #expect(player.modifierDiagnostics.first?.status == .disabled)
    }

    @Test
    func invalidChainsAndBindingIDsAreRejectedAtomically() throws {
        var player = try chain()
        let binding = AnimationRigBinding(rig: player.rig, sourceAsset: "Robot.glb")
        let valid = AnimationPoseModifier(id: "ik", kind: .twoBone, joints: ["node-0", "node-1", "node-2"], target: [1, 1, 0])
        try player.setPoseModifiers([valid], binding: binding)
        let final = player.poses
        var invalid = valid
        invalid.joints = ["node-0", "node-2", "node-1"]
        #expect(throws: AnimationPoseModifierError.invalidChain("ik")) { try player.setPoseModifiers([invalid], binding: binding) }
        #expect(player.poseModifiers == [valid])
        #expect(player.poses == final)
        var duplicate = binding
        duplicate.nodes[1].id = duplicate.nodes[0].id
        #expect(throws: AnimationPoseModifierError.incompatibleRig) { try player.setPoseModifiers([valid], binding: duplicate) }
        var zero = try chain(lengths: [0, 1])
        #expect(throws: AnimationPoseModifierError.invalidChain("ik")) {
            try zero.setPoseModifiers([valid], binding: AnimationRigBinding(rig: zero.rig, sourceAsset: "Robot.glb"))
        }
    }

    @Test
    func nearOppositeDirectionsAndNearRootFoldingRetainSmallTargetDeviations() throws {
        for target: Vector3 in [[-2, 0.002, 0], [0.001, 0, 0]] {
            var player = try chain()
            try player.setPoseModifiers([.init(id: "arm", kind: .twoBone, joints: ["node-0", "node-1", "node-2"], target: target)],
                                        binding: AnimationRigBinding(rig: player.rig, sourceAsset: "Robot.glb"))
            #expect((player.globalTransforms[2].origin - target).length < 0.0002)
            #expect((player.modifierDiagnostics.first?.reachError ?? 1) < 0.0002)
        }
    }

    @Test
    func pausedTargetInputsReplaceOnlyTheFinalPoseAndMissingTargetsRestoreBase() throws {
        var player = try chain()
        let configuration = AnimationPoseModifier(id: "ik", kind: .twoBone, joints: ["node-0", "node-1", "node-2"], target: [2, 0, 0])
        try player.setPoseModifiers([configuration], binding: AnimationRigBinding(rig: player.rig, sourceAsset: "Robot.glb"))
        let generation = player.basePoseGeneration
        player.isPlaying = false
        player.finalizePoseModifiers(inputs: ["ik": .init(target: [0, 2, 0])])
        #expect((player.globalTransforms[2].origin - Vector3(0, 2, 0)).length < 0.0001)
        #expect(player.basePoseGeneration == generation)
        #expect(player.time == 0)
        #expect(player.poseModifiers == [configuration])
        player.finalizePoseModifiers(inputs: ["ik": .init(target: nil)])
        #expect(player.poses == player.basePoses)
        #expect(player.modifierDiagnostics.first?.status == .invalidTarget)
        player.finalizePoseModifiers(inputs: ["ik": .init(target: [0, 2, 0], supportsTransform: false)])
        #expect(player.poses == player.basePoses)
        #expect(player.modifierDiagnostics.first?.status == .unsupportedTransform)
    }

    @Test
    func reversedAndRotatedBoneAxesUseActualParentFrames() throws {
        for axis: Vector3 in [[-1, 0, 0], [0, 1, 0], [0, 0, 1]] {
            let root = SkeletalJointPose(translation: [3, 2, -1], rotation: Quat(axis: [1, 1, 0], angle: 1.1), scale: Vector3(2))
            let child = SkeletalJointPose(translation: axis)
            let rig = try SkeletalRig(nodes: [
                .init(parentIndex: nil, restPose: root, restMatrix: root.matrix),
                .init(parentIndex: 0, restPose: child, restMatrix: child.matrix),
                .init(parentIndex: 1, restPose: child, restMatrix: child.matrix)
            ])
            var player = try SkeletalAnimationPlayer(rig: rig, clips: [])
            let target = root.translation + Vector3(1, -1, 1)
            try player.setPoseModifiers([.init(kind: .twoBone, joints: ["node-0", "node-1", "node-2"], target: target)],
                                        binding: AnimationRigBinding(rig: rig, sourceAsset: "Robot.glb"))
            #expect((player.globalTransforms[2].origin - target).length < 0.0001)
        }
    }

    private func chain(lengths: [Float] = [1, 1]) throws -> SkeletalAnimationPlayer {
        let poses = [SkeletalJointPose(), SkeletalJointPose(translation: [lengths[0], 0, 0]), SkeletalJointPose(translation: [lengths[1], 0, 0])]
        let rig = try SkeletalRig(nodes: poses.enumerated().map { index, pose in
            .init(parentIndex: index == 0 ? nil : index - 1, restPose: pose, restMatrix: pose.matrix)
        })
        return try SkeletalAnimationPlayer(rig: rig, clips: [])
    }

    @Test
    func longFabrikChainPreservesExportedAxesAndRepeatsFromTheSameBase() throws {
        let poses = [SkeletalJointPose(translation: [2, -1, 3], rotation: Quat(axis: [1, 2, 3], angle: 0.8), scale: Vector3(1.5))]
            + ([Vector3(0, 1, 0), Vector3(0, 0, -0.7), Vector3(-0.8, 0, 0), Vector3(0, 0.6, 0), Vector3(0, 0, 0.9)]).map {
                SkeletalJointPose(translation: $0, rotation: Quat(axis: [1, 1, 0], angle: 0.2))
            }
        let rig = try SkeletalRig(nodes: poses.enumerated().map { index, pose in
            .init(parentIndex: index == 0 ? nil : index - 1, restPose: pose, restMatrix: pose.matrix)
        })
        var player = try SkeletalAnimationPlayer(rig: rig, clips: [])
        let base = player.basePoses, globals = player.globalTransforms
        let lengths = (1..<poses.count).map { (globals[$0].origin - globals[$0 - 1].origin).length }
        let target = poses[0].translation + Vector3(1.2, 0.7, -0.5)
        try player.setPoseModifiers([.init(id: "tail", kind: .fabrik, joints: poses.indices.map { "node-\($0)" }, target: target,
                                          iterations: 64, tolerance: 0.0001)], binding: AnimationRigBinding(rig: rig, sourceAsset: "Tail.glb"))
        #expect((player.globalTransforms[poses.count - 1].origin - target).length < 0.0002)
        let solved = player.poses
        for _ in 0..<20 { player.finalizePoseModifiers() }
        #expect(player.poses == solved)
        #expect(player.basePoses == base)
        for index in 1..<poses.count {
            #expect(abs((player.globalTransforms[index].origin - player.globalTransforms[index - 1].origin).length - lengths[index - 1]) < 0.0001)
            #expect(player.poses[index].translation == base[index].translation)
            #expect(player.poses[index].scale == base[index].scale)
        }
    }

    @Test
    func overlappingModifiersObservePriorBlendedResultInSavedOrder() throws {
        var combined = try chain(), sequential = try chain()
        let binding = AnimationRigBinding(rig: combined.rig, sourceAsset: "Robot.glb")
        let first = AnimationPoseModifier(id: "first", kind: .twoBone, joints: ["node-0", "node-1", "node-2"],
                                         target: [0, 2, 0], pole: [0, 0, 1], influence: 0.5)
        let second = AnimationPoseModifier(id: "second", kind: .twoBone, joints: first.joints,
                                          target: [1, 0, 1], pole: [0, 1, 0], influence: 0.5)
        try combined.setPoseModifiers([first, second], binding: binding)
        try sequential.setPoseModifiers([first], binding: binding)
        let firstPose = sequential.poses
        try sequential.setPoseModifiers([], binding: binding)
        sequential.presentPose(from: firstPose, to: firstPose, amount: 0)
        try sequential.setPoseModifiers([second], binding: binding)
        for index in combined.poses.indices {
            #expect((combined.globalTransforms[index].origin - sequential.globalTransforms[index].origin).length < 0.0001)
        }
        let saved = combined.poses
        for _ in 0..<20 { combined.finalizePoseModifiers() }
        #expect(combined.poses == saved)
        try combined.setPoseModifiers([second, first], binding: binding)
        #expect((combined.globalTransforms[2].origin - sequential.globalTransforms[2].origin).length > 0.01)
    }
}
