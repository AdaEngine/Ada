import AdaAnimation
import Foundation
import Math
import Testing

@Suite
struct AnimationGraphTests {
    @Test func weightedBlendMasksAndRestFallback() throws {
        var player = try makePlayer()
        let graph = AnimationGraph(
            root: "Mix",
            nodes: [
                .init(id: "A", clip: "Move"), .init(id: "B", clip: "Pose"),
                .init(
                    id: "Mix", 
                    kind: .blend,
                    inputs: [
                        .init(node: "A", weight: 0.75),
                        .init(node: "B", weight: 0.25, mask: .init(joints: [.init(nodeIndex: 1)])),
                    ]
                ),
            ]
        )
        try player.play(graph, transitionDuration: 0)
        player.seek(to: 0.5)
        #expect(abs(player.poses[0].translation.x - 0.75) < 0.00001)
        #expect(abs(player.poses[1].translation.y - 1.75) < 0.00001)
        #expect(player.poses[2].translation.y == 0.5, "Subtree masks include descendants")
        try player.setGraphWeight(0, node: "Mix", input: 1)
        #expect(player.time == 0.5)
        #expect(player.poses[1].translation.y == 1, "Unanimated channels retain the rig's rest pose")
    }

    @Test func additiveIsRelativeToRestAndKeepsUnmaskedBones() throws {
        var player = try makePlayer()
        let graph = AnimationGraph(
            root: "Layer",
            nodes: [
                .init(id: "Base", clip: "Move"), .init(id: "Upper", clip: "Pose"),
                .init(
                    id: "Layer", 
                    kind: .additive,
                    inputs: [
                        .init(node: "Base"), .init(node: "Upper", weight: 0.5, mask: .init(joints: [.init(nodeIndex: 1, includesDescendants: false)])),
                    ]
                ),
            ]
        )
        try player.play(graph, transitionDuration: 0)
        player.seek(to: 0.5)
        #expect(player.poses[0].translation.x == 1)
        #expect(player.poses[1].translation.y == 2.5)
        #expect(player.poses[2].translation == .zero)
        #expect(player.poses[1].scale.x == 1.5)
        #expect(abs(player.poses[1].rotation.angle(to: .identity) - Float.pi / 4) < 0.0001)
    }

    @Test func blendNormalizesLargeWeights() throws {
        var player = try makePlayer()
        let graph = AnimationGraph(
            root: "Mix",
            nodes: [
                .init(id: "A", clip: "Move"), .init(id: "B", clip: "Pose"),
                .init(id: "Mix", kind: .blend, inputs: [.init(node: "A", weight: 3), .init(node: "B", weight: 1)]),
            ]
        )
        try player.play(graph, transitionDuration: 0)
        player.seek(to: 0.5)
        #expect(player.poses[0].translation.x == 2.75)
        #expect(abs(player.poses[1].rotation.squaredLength - 1) < 0.00001)
    }

    @Test func antipodalHalfTurnsDoNotCancelAgainstAnOrthogonalRestPose() throws {
        let rig = try makePlayer().rig
        func clip(_ name: String, rotation: Vector4) throws -> SkeletalAnimationClip {
            .init(name: name, tracks: [try .init(nodeIndex: 0, path: .rotation, interpolation: .linear, times: [0], values: [rotation])])
        }
        var player = try SkeletalAnimationPlayer(rig: rig, clips: [
            clip("Positive", rotation: [1, 0, 0, 0]), clip("Negative", rotation: [-1, 0, 0, 0]),
        ])
        try player.play(AnimationGraph(root: "Mix", nodes: [
            .init(id: "A", clip: "Positive"), .init(id: "B", clip: "Negative"),
            .init(id: "Mix", kind: .blend, inputs: [.init(node: "A", weight: 0.5), .init(node: "B", weight: 0.5)]),
        ]), transitionDuration: 0)
        #expect(abs(player.poses[0].rotation.x) == 1)
        #expect(player.poses[0].rotation.w == 0)
    }

    @Test func eventsCrossLoopsReverseAndVisualLODExactlyOnce() throws {
        var player = try makePlayer()
        let graph = AnimationGraph(
            root: "Move",
            nodes: [
                .init(id: "Move", clip: "Move", events: [.init(time: 0.25, name: "Step", payload: "left")])
            ]
        )
        try player.play(graph, transitionDuration: 0)
        player.advance(by: 2.5, evaluatePose: false)
        let events = player.drainGraphEvents()
        #expect(events.map(\.graphTime) == [0.25, 1.25, 2.25])
        #expect(events.allSatisfy { $0.marker.payload == "left" && $0.weight == 1 })
        player.sampleCurrentPose()
        #expect(player.drainGraphEvents().isEmpty)
        player.speed = -1
        player.advance(by: 1.5, evaluatePose: false)
        #expect(player.drainGraphEvents().map(\.graphTime) == [2.25, 1.25])
        player.seek(to: 0.75)
        #expect(player.drainGraphEvents().isEmpty)
        player.isPlaying = false
        player.advance(by: 5)
        #expect(player.time == 0.75)
    }

    @Test func sharedClipEventsAreNotDuplicatedAndMutedBranchesStaySilent() throws {
        var player = try makePlayer()
        let clip = AnimationGraph.Node(id: "Clip", clip: "Move", events: [.init(time: 0.25, name: "Step")])
        let graph = AnimationGraph(
            root: "Mix",
            nodes: [
                clip,
                .init(id: "Mix", kind: .blend, inputs: [.init(node: "Clip", weight: 0.5), .init(node: "Clip", weight: 0.5)]),
            ]
        )
        try player.play(graph, transitionDuration: 0)
        player.advance(by: 0.5)
        #expect(player.drainGraphEvents().count == 1)
        try player.setGraphWeight(0, node: "Mix", input: 0)
        try player.setGraphWeight(0, node: "Mix", input: 1)
        player.advance(by: 1)
        #expect(player.drainGraphEvents().isEmpty)
    }

    @Test func invalidEditsAreAtomicAndSerializationPreservesGraph() throws {
        var player = try makePlayer()
        let graph = AnimationGraph(root: "Clip", nodes: [.init(id: "Clip", clip: "Move")])
        let decoded = try JSONDecoder().decode(AnimationGraph.self, from: JSONEncoder().encode(graph))
        #expect(decoded == graph)
        try player.play(graph, transitionDuration: 0)
        player.advance(by: 0.5)
        let bad = AnimationGraph(root: "Loop", nodes: [.init(id: "Loop", kind: .blend, inputs: [.init(node: "Loop")])])
        #expect(throws: AnimationGraphError.cycle("Loop")) { try player.play(bad) }
        #expect(player.graph == graph)
        #expect(player.time == 0.5)
        #expect(throws: AnimationGraphError.invalidWeight) { try player.setGraphWeight(.nan, node: "Clip", input: 0) }
        try player.play("Move", transitionDuration: 0)
        #expect(player.graph == nil)
    }

    @Test func nonloopingGraphClampsAndEventsAreBounded() throws {
        var player = try makePlayer()
        let once = AnimationGraph(root: "Clip", nodes: [.init(id: "Clip", clip: "Move", repeats: false, events: [.init(time: 1, name: "End")])])
        try player.play(once, transitionDuration: 0)
        player.advance(by: 10)
        #expect(player.time == 1)
        #expect(!player.isPlaying)
        #expect(player.drainGraphEvents().map(\.marker.name) == ["End"])
        let loop = AnimationGraph(root: "Clip", nodes: [.init(id: "Clip", clip: "Move", events: [.init(time: 0, name: "Loop")])])
        try player.play(loop, transitionDuration: 0)
        player.advance(by: 2_000)
        #expect(player.drainGraphEvents().count == 1_024)
        #expect(player.droppedGraphEventCount == 976)
    }

    private func makePlayer() throws -> SkeletalAnimationPlayer {
        let rest = SkeletalJointPose(translation: [0, 1, 0])
        let rig = try SkeletalRig(nodes: [
            .init(parentIndex: nil, restPose: .init(), restMatrix: .identity, name: "Root"),
            .init(parentIndex: 0, restPose: rest, restMatrix: rest.matrix, name: "Upper"),
            .init(parentIndex: 1, restPose: .init(), restMatrix: .identity, name: "Hand"),
        ])
        func track(_ index: Int, _ path: SkeletalAnimationTrack.Path, _ first: Vector4, _ last: Vector4) throws -> SkeletalAnimationTrack {
            try .init(nodeIndex: index, path: path, interpolation: .linear, times: [0, 1], values: [first, last])
        }
        let rotation = Quat(axis: .up, angle: .pi / 2)
        let move = SkeletalAnimationClip(name: "Move", tracks: [try track(0, .translation, .zero, [2, 0, 0, 0])])
        let pose = SkeletalAnimationClip(
            name: "Pose",
            tracks: [
                try track(0, .translation, [8, 0, 0, 0], [8, 0, 0, 0]),
                try track(1, .translation, [0, 4, 0, 0], [0, 4, 0, 0]),
                try track(2, .translation, [0, 2, 0, 0], [0, 2, 0, 0]),
                try track(1, .scale, [2, 2, 2, 0], [2, 2, 2, 0]),
                try track(1, .rotation, [rotation.x, rotation.y, rotation.z, rotation.w], [rotation.x, rotation.y, rotation.z, rotation.w]),
            ]
        )
        return try SkeletalAnimationPlayer(rig: rig, clips: [move, pose])
    }
}
