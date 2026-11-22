import AdaAnimation
import Foundation
import Math
import Testing

@Suite
struct SOMAHumanoidMotionTests {
    @Test
    func transfersAsymmetricArmAndRootToEditableLibrary() throws {
        let rig = try referenceRig()
        let motion = try fixture()
        let clip = try motion.clip(named: "Wave", for: rig)
        var library = AnimationLibrary(binding: .init(rig: rig, sourceAsset: "Assets/Hero.glb"))
        try library.extract(clip, rig: rig)

        let reopened = try AnimationLibrary.decode(library.encodedData())
        let playable = try #require(reopened.compiledClips(for: rig).first)
        let root = try #require(playable.tracks.first { $0.nodeIndex == 0 && $0.path == .translation })
        let rightArm = try #require(playable.tracks.first { $0.nodeIndex == 5 && $0.path == .rotation })
        let leftArm = try #require(playable.tracks.first { $0.nodeIndex == 3 && $0.path == .rotation })
        #expect(root.values == [Vector4(0, 1, 0, 0), Vector4(0, 1, 2, 0)])
        #expect(rightArm.values[0] != rightArm.values[1])
        #expect(leftArm.values[0] == leftArm.values[1])
        #expect(playable.duration == 2.0 / 30)
    }

    @Test
    func rejectsMissingRequiredJointBeforeGeneration() throws {
        let rig = try SkeletalRig(nodes: [])
        #expect(throws: SOMAHumanoidMotion.Failure.unsupportedJoint("Root")) {
            try SOMAHumanoidMotion.validateTarget(rig)
        }
    }

    private func referenceRig() throws -> SkeletalRig {
        let nodes: [(String, Int?)] = [
            ("Root", nil), ("Spine", 0), ("Head", 1), ("ArmL", 1), ("ForeArmL", 3), ("ArmR", 1), ("ForeArmR", 5),
            ("LegL", 0), ("LowerLegL", 7), ("LegR", 0), ("LowerLegR", 9)
        ]
        return try SkeletalRig(nodes: nodes.enumerated().map { index, entry in
            let pose = SkeletalJointPose(translation: index == 0 ? [0, 1, 0] : .zero)
            return .init(parentIndex: entry.1, restPose: pose, restMatrix: pose.matrix, name: entry.0)
        })
    }

    private func fixture() throws -> SOMAHumanoidMotion {
        let joints = ["Hips", "Chest", "Head", "LeftArm", "LeftForeArm", "RightArm", "RightForeArm", "LeftLeg", "LeftShin", "RightLeg", "RightShin"]
        let rest = Array(repeating: [Float(0), 0, 0, 1], count: joints.count)
        var wave = rest
        wave[5] = [0, 0, 0.70710677, 0.70710677]
        wave[6] = wave[5]
        let payload: [String: Any] = [
            "protocolVersion": 1, "jobID": UUID().uuidString, "framesPerSecond": 30, "jointNames": joints,
            "referenceHeight": 0.5, "rootPositions": [[0, 0.5, 0], [0, 0.5, 1]], "globalRotations": [rest, wave]
        ]
        return try JSONDecoder().decode(SOMAHumanoidMotion.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}
