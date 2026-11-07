import AdaAnimation
@testable import AdaAssets
import Foundation
import Math
import Testing

@Suite
struct AnimationModifierResourceTests {
    @Test
    func portableStackRoundTripsThroughProductionAssetCodecs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AnimationIK-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("arm.animmod")
        let meta = AssetMeta(filePath: path, queryParams: [])
        let stack = try fixture()
        let resource = try AnimationModifierResource(stack: stack)
        let encoder = TextAssetEncoder(meta: meta)
        try await resource.encodeContents(with: encoder)
        let bytes = try #require(encoder.encodedData)
        try bytes.write(to: path)
        let loaded = try await AnimationModifierResource(from: TextAssetDecoder(meta: meta, data: Data(contentsOf: path)))
        #expect(loaded.stack == stack)
        #expect(AnimationModifierResource.extensions() == ["animmod"])
        #expect(try AnimationModifierStack.decode(stack.encodedData()) == stack)
    }

    @Test
    func invalidVersionsDuplicateIDsAndOversizedStacksFailBeforeInstallation() throws {
        var stack = try fixture()
        stack.version = 99
        #expect(throws: AnimationPoseModifierError.self) { _ = try AnimationModifierStack.decode(JSONEncoder().encode(stack)) }
        stack.version = 1
        stack.modifiers.append(stack.modifiers[0])
        #expect(throws: AnimationPoseModifierError.self) { _ = try AnimationModifierResource(stack: stack) }
        #expect(throws: AnimationPoseModifierError.limitExceeded) {
            _ = try AnimationModifierStack.decode(Data(repeating: 32, count: AnimationModifierStack.maximumEncodedBytes + 1))
        }
    }

    private func fixture() throws -> AnimationModifierStack {
        let poses = [SkeletalJointPose(), SkeletalJointPose(translation: [1, 0, 0]), SkeletalJointPose(translation: [1, 0, 0])]
        let rig = try SkeletalRig(nodes: poses.indices.map {
            .init(parentIndex: $0 == 0 ? nil : $0 - 1, restPose: poses[$0], restMatrix: poses[$0].matrix)
        })
        return AnimationModifierStack(id: "arm", binding: AnimationRigBinding(rig: rig, sourceAsset: "Robot.glb"), modifiers: [
            .init(id: "elbow", kind: .twoBone, joints: ["node-0", "node-1", "node-2"], target: [1, 1, 0])
        ])
    }
}
