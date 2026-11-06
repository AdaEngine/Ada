import AdaAnimation
import Foundation
import Math
import Testing

@Suite
struct AnimationLibraryTests {
    @Test
    func rejectsNegativeDurationWhenDecodingAnAuthoredLibrary() throws {
        let library = AnimationLibrary(binding: .init(sourceAsset: "hero.glb", nodes: []), clips: [
            .init(id: "wave", name: "Wave", duration: -1)
        ])
        let data = try JSONEncoder().encode(library)
        #expect(throws: AnimationAuthoringError.self) {
            _ = try AnimationLibrary.decode(data)
        }
    }

    @Test(arguments: 0..<14)
    func rejectsMalformedBindingsAndTracks(_ scenario: Int) throws {
        var library = Self.library()
        switch scenario {
        case 0: library.version = 3
        case 1: library.clips.append(library.clips[0])
        case 2: library.binding.nodes[0].parentID = "bone"
        case 3: library.clips[0].tracks[0].nodeID = "missing"
        case 4: library.clips[0].tracks[0].keys[0].time = 2
        case 5: library.clips[0].tracks[0].keys[0].value = [.nan, 0, 0]
        case 6: library.clips[0].tracks[0].keys.append(.init(time: 0, value: [1, 0, 0]))
        case 7:
            library.clips[0].tracks[0].channel = .rotation
            library.clips[0].tracks[0].keys[0].value = [0, 0, 0, 0]
        case 8: library.clips[0].tracks[0].interpolation = .cubicSpline
        case 9: library.clips[0].tracks.append(library.clips[0].tracks[0])
        case 10: library.binding.nodes[0].restScale = nil
        case 11: library.clips[0].tracks[0].channel = .weights
        case 12: library.clips[0].name = String(repeating: "x", count: 1025)
        default: library.binding.sourceAsset = String(repeating: "x", count: 4097)
        }
        #expect(throws: AnimationAuthoringError.self) { try library.validate() }
    }

    @Test
    func validLibraryRoundTripsWithStableIdentities() throws {
        let library = Self.library()
        try library.validate()
        let decoded = try AnimationLibrary.decode(JSONEncoder().encode(library))
        #expect(decoded == library)
        #expect(decoded.clips[0].tracks[0].keys[0].id == "start")
    }

    @Test
    func extractionPreservesCubicPoseAndMorphSamples() throws {
        let rig = try Self.rig()
        let translation = try SkeletalAnimationTrack(nodeIndex: 1, path: .translation, interpolation: .cubicSpline, times: [0, 2],
                                                    values: [.zero, .zero, [1, 0, 0, 0], .zero, [2, 0, 0, 0], .zero])
        let rotation = try SkeletalAnimationTrack(nodeIndex: 1, path: .rotation, interpolation: .cubicSpline, times: [0, 2],
                                                 values: [.zero, [0, 0, 0, 1], [0, 0, 1, 0], .zero, [0, 0, 1, 0], .zero])
        let morph = try MorphWeightsTrack(nodeIndex: 1, interpolation: .cubicSpline, times: [0, 2], targetCount: 2,
                                         values: [0, 0, 0.25, 0.75, 1, -1, 0, 0, 0.75, 0.25, 0, 0])
        let source = SkeletalAnimationClip(name: "Walk", tracks: [translation, rotation], morphTracks: [morph])
        var library = AnimationLibrary(id: "hero", binding: .init(rig: rig, sourceAsset: "hero.glb"))
        try library.extract(source, rig: rig, id: "copy", sourceFingerprint: "source-checksum")
        library.clips[0].repeats = false
        let decoded = try AnimationLibrary.decode(JSONEncoder().encode(library))
        var original = try SkeletalAnimationPlayer(rig: rig, clips: [source])
        original.repeats = false
        try original.play("Walk", transitionDuration: 0)
        for time in [0, 0.25, 1, 1.75, 2] {
            original.seek(to: time)
            var copy = try decoded.sample(clipID: "copy", at: time)
            #expect(copy.poses == original.poses)
            #expect(copy.globalTransforms == original.globalTransforms)
            #expect(copy.morphWeights == original.morphWeights)
            #expect(copy.drainGraphEvents().isEmpty)
        }
        #expect(decoded.clips[0].tracks[0].keys[0].outgoing == [1, 0, 0])
        #expect(decoded.clips[0].sourceFingerprint == "source-checksum")
        #expect(source.tracks[0].values == translation.values)
    }

    @Test
    func explicitDurationHoldsAfterLastKeyAndSupportsEmptyPoseClips() throws {
        var library = Self.library()
        library.clips[0].duration = 3
        library.clips[0].repeats = false
        library.clips[0].tracks[0].keys.append(.init(id: "end", time: 1, value: [2, 0, 0]))
        let rig = try library.binding.makeRig()
        let compiled = try library.compiledClips(for: rig)
        #expect(compiled[0].duration == 3)
        #expect(try library.sample(clipID: "wave", at: 2).poses[0].translation.x == 2)
        library.clips[0].tracks = []
        #expect(try library.compiledClips(for: rig)[0].duration == 3)
        #expect(try library.sample(clipID: "wave", at: 2).poses[0].translation == .zero)
    }

    @Test
    func rejectsInconsistentRestTransformsBeforeSampling() {
        var library = Self.library()
        library.binding.nodes[0].restTranslation = [10, 0, 0]
        #expect(throws: AnimationAuthoringError.self) { try library.validate() }
    }

    @Test
    func changedSourceRigRequiresExplicitRemapping() throws {
        let rig = try Self.rig()
        let library = AnimationLibrary(binding: .init(rig: rig, sourceAsset: "hero.glb"))
        let changed = try SkeletalRig(nodes: [.init(parentIndex: nil, restPose: .init(), restMatrix: .identity, name: "Changed")])
        #expect(!library.binding.isCompatible(with: changed))
        #expect(throws: AnimationAuthoringError.self) { _ = try library.compiledClips(for: changed) }
        #expect(library.binding.isCompatible(with: try library.binding.makeRig()))
    }

    @Test
    func clipsWithSameDisplayNameHaveDistinctGraphReferences() throws {
        var library = Self.library()
        var second = library.clips[0]
        second.id = "other"
        second.tracks[0].keys[0].value = [4, 0, 0]
        library.clips.append(second)
        let rig = try library.binding.makeRig()
        var player = try SkeletalAnimationPlayer(rig: rig, clips: library.compiledClips(for: rig))
        try player.play(AnimationGraph(root: "blend", nodes: [
            .init(id: "a", clip: library.runtimeName(for: "wave")),
            .init(id: "b", clip: library.runtimeName(for: "other")),
            .init(id: "blend", kind: .blend, inputs: [.init(node: "a", weight: 0.5), .init(node: "b", weight: 0.5)])
        ]), transitionDuration: 0)
        #expect(player.poses[0].translation.x == 2)
    }

    @Test
    func failedCommandBatchPreservesOriginalAndIdentifiesTheOperation() throws {
        var library = Self.library()
        let original = library
        let edits: [AnimationEdit] = [
            .init(id: "rename", kind: .configureClip, clipID: "wave", name: "Changed"),
            .init(id: "bad-key", kind: .putKey, clipID: "wave", trackID: "hand-position", key: .init(time: 2, value: [1, 0, 0]))
        ]
        do {
            try library.apply(edits)
            Issue.record("Invalid key edit was committed")
        } catch {
            #expect(error.operationID == "bad-key")
            #expect(error.diagnostic.code == .invalidKey)
        }
        #expect(library == original)
    }

    @Test
    func keyReplacementAndTimeConflictsAreExplicit() throws {
        var library = Self.library()
        let replacement = AnimationLibraryKey(id: "start", time: 0, value: [2, 0, 0])
        #expect(throws: AnimationEditError.self) {
            try library.apply([.init(kind: .putKey, clipID: "wave", trackID: "hand-position", key: replacement)])
        }
        try library.apply([.init(kind: .putKey, clipID: "wave", trackID: "hand-position", key: replacement, replaceExisting: true)])
        #expect(try library.sample(clipID: "wave", at: 0).poses[0].translation.x == 2)
        #expect(throws: AnimationEditError.self) {
            try library.apply([.init(kind: .putKey, clipID: "wave", trackID: "hand-position",
                                    key: .init(id: "different", time: 0, value: [4, 0, 0]), replaceExisting: true)])
        }
    }

    @Test
    func scriptCommandMayOmitOptionalReplacementFlag() throws {
        let json = Data(#"{"id":"rename","kind":"clip.configure","clipID":"wave","name":"Renamed"}"#.utf8)
        let edit = try? JSONDecoder().decode(AnimationEdit.self, from: json)
        #expect(edit != nil)
        var library = Self.library()
        try library.apply([try #require(edit)])
        #expect(library.clips[0].name == "Renamed")
    }

    @Test
    func capturedPoseClipAndDuplicateDoNotShareSourceKeys() throws {
        var library = Self.library()
        var player = try library.sample(clipID: "wave", at: 0)
        player.isPlaying = true
        let pose = try library.poseClip(id: "pose", name: "Pose", duration: 2, from: player)
        try library.apply([
            .init(kind: .createClip, clip: pose),
            .init(kind: .duplicateClip, clipID: "wave", newID: "duplicate", name: "Copy")
        ])
        let copyIndex = try #require(library.clips.firstIndex { $0.id == "duplicate" })
        library.clips[copyIndex].tracks[0].keys[0].value = [5, 0, 0]
        #expect(library.clips[0].tracks[0].keys[0].value == [0, 0, 0])
        #expect(try library.sample(clipID: "pose", at: 1).poses == player.poses)
    }

    @Test
    func capturedPosePreservesMatrixAuthoredNodesAndTheirMorphs() throws {
        let staticMatrix = Transform3D(translation: [3, 0, 0])
        let rig = try SkeletalRig(nodes: [
            .init(parentIndex: nil, restPose: nil, restMatrix: staticMatrix, morphRestWeights: [0.3]),
            .init(parentIndex: 0, restPose: .init(), restMatrix: .identity)
        ])
        let player = try SkeletalAnimationPlayer(rig: rig, clips: [])
        var library = AnimationLibrary(binding: .init(rig: rig, sourceAsset: "mixed.glb"))
        let clip = try? library.poseClip(id: "pose", name: "Pose", duration: 1, from: player)
        #expect(clip != nil)
        try library.apply([.init(kind: .createClip, clip: try #require(clip))])
        let captured = try library.sample(clipID: "pose", at: 0.5)
        #expect(captured.globalTransforms == player.globalTransforms)
        #expect(captured.morphWeights == player.morphWeights)
        #expect(library.clips[0].tracks.filter { $0.nodeID == "node-0" }.allSatisfy { $0.channel == .weights })
    }

    private static func rig() throws -> SkeletalRig {
        let child = SkeletalJointPose(translation: [0, 1, 0])
        return try SkeletalRig(nodes: [
            .init(parentIndex: nil, restPose: .init(), restMatrix: .identity, name: "Bone"),
            .init(parentIndex: 0, restPose: child, restMatrix: child.matrix, name: "Bone", morphRestWeights: [0.25, 0.75])
        ])
    }

    private static func library() -> AnimationLibrary {
        .init(id: "hero", binding: .init(sourceAsset: "hero.glb", nodes: [
            .init(id: "bone", name: "Hand", restTranslation: .zero, restRotation: [0, 0, 0, 1], restScale: .one)
        ]), clips: [
            .init(id: "wave", name: "Wave", duration: 1, tracks: [
                .init(id: "hand-position", nodeID: "bone", channel: .translation, keys: [
                    .init(id: "start", time: 0, value: [0, 0, 0])
                ])
            ])
        ])
    }
}
