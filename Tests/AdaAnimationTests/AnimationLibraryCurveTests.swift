import AdaAnimation
import Foundation
import Math
import Testing

@Suite
struct AnimationLibraryCurveTests {
    @Test
    func extractingCompiledNativeCurvesPreservesTheirShapeAndSchema() throws {
        for kind: AnimationLibraryTrack.Interpolation in [.linear, .bezier, .cubicSpline] {
            var source = try fixture()
            source.clips[0].tracks.append(.init(id: "weights", nodeID: "node-0", channel: .weights, keys: [
                .init(time: 0, value: [0, 0]), .init(time: 1, value: [1, 0])
            ]))
            for index in source.clips[0].tracks.indices {
                source.clips[0].tracks[index].interpolation = kind
                let width = source.clips[0].tracks[index].keys[0].value.count
                source.clips[0].tracks[index].keys[0].curve = .init(easing: .init(family: .quadratic, direction: .in))
                if kind == .bezier {
                    source.clips[0].tracks[index].keys[0].curve?.outgoing = Array(repeating: .init(timeOffset: 0, valueOffset: 0), count: width)
                    source.clips[0].tracks[index].keys[1].curve = .init(incoming: Array(repeating: .init(timeOffset: -1, valueOffset: 0), count: width))
                }
                if kind == .cubicSpline {
                    for key in 0..<2 {
                        source.clips[0].tracks[index].keys[key].incoming = [1] + Array(repeating: 0, count: width - 1)
                        source.clips[0].tracks[index].keys[key].outgoing = [1] + Array(repeating: 0, count: width - 1)
                    }
                }
            }
            let rig = try source.binding.makeRig(), clip = try #require(source.compiledClips(for: rig).first)
            var copy = AnimationLibrary(binding: source.binding)
            let extracted = (try? copy.extract(clip, rig: rig, id: "copy")) != nil
            #expect(extracted)
            #expect(copy.version == 2)
            let expected = try source.sample(clipID: "clip", at: 0.125)
            let actual = try? copy.sample(clipID: "copy", at: 0.125)
            #expect(abs((actual?.poses[0].translation.x ?? -1) - expected.poses[0].translation.x) < 0.000001)
            #expect(abs((actual?.morphWeights[0][0] ?? -1) - expected.morphWeights[0][0]) < 0.000001)
        }
    }

    @Test
    func rotationEasingUsesSlerpAndUnchangedCubicMetadataRetainsExactImportedSampling() throws {
        var library = try fixture()
        let end = Quat(axis: [0, 0, 1], angle: .pi / 2)
        library.clips[0].tracks = [.init(id: "rotation", nodeID: "node-0", channel: .rotation, keys: [
            .init(time: 0, value: [0, 0, 0, 1], curve: .init(easing: .init(family: .quadratic, direction: .in))),
            .init(time: 1, value: [end.x, end.y, end.z, end.w])
        ])]
        let eased = try library.sample(clipID: "clip", at: 0.5).poses[0].rotation
        let expected = Quat(axis: [0, 0, 1], angle: .pi / 8)
        #expect(abs(eased.z - expected.z) < 0.000001 && abs(eased.w - expected.w) < 0.000001)
        library.clips[0].tracks[0].interpolation = .cubicSpline
        for key in 0..<2 {
            library.clips[0].tracks[0].keys[key].curve = nil
            library.clips[0].tracks[0].keys[key].incoming = [0, 0, 0, 0]
            library.clips[0].tracks[0].keys[key].outgoing = [0, 0, 0, 0]
        }
        let original = try library.sample(clipID: "clip", at: 0.3).poses[0].rotation
        library.clips[0].tracks[0].keys[0].curve = .init(easing: .init())
        #expect(try library.sample(clipID: "clip", at: 0.3).poses[0].rotation == original)
        let quarter = try library.sample(clipID: "clip", at: 0.25).poses[0].rotation
        library.clips[0].tracks[0].keys[0].curve = .init(easing: .init(family: .quadratic, direction: .in))
        let warped = try library.sample(clipID: "clip", at: 0.5).poses[0].rotation
        #expect(abs(warped.z - quarter.z) < 0.000001 && abs(warped.w - quarter.w) < 0.000001)
    }

    @Test
    func sparseEasingCompilesOnlyTheEditedSegmentsOfADenseMorphTrack() throws {
        let pose = SkeletalJointPose(), width = 128
        let rig = try SkeletalRig(nodes: [.init(parentIndex: nil, restPose: pose, restMatrix: pose.matrix,
                                              morphRestWeights: Array(repeating: 0, count: width))])
        var keys = (0..<4_000).map { AnimationLibraryKey(id: "weight-\($0)", time: Double($0) / 10, value: Array(repeating: Float($0 % 2), count: width)) }
        keys[0].curve = .init(easing: .init(family: .quadratic, direction: .in))
        let library = AnimationLibrary(binding: .init(rig: rig, sourceAsset: "Dense.glb"), clips: [
            .init(id: "dense", name: "Dense", duration: 400, repeats: false, tracks: [.init(nodeID: "node-0", channel: .weights, keys: keys)])
        ], version: 2)
        let first = try? library.sample(clipID: "dense", at: 0.05)
        let unchanged = try? library.sample(clipID: "dense", at: 0.15)
        #expect(abs((first?.morphWeights.first?.last ?? -1) - 0.25) < 0.00001)
        #expect(abs((unchanged?.morphWeights.first?.last ?? -1) - 0.5) < 0.00001)
    }

    @Test
    func nativeCurveEditsPromoteSchemaWithoutChangingLegacyAssets() throws {
        var library = try fixture()
        library.version = 1
        let legacy = try library.encodedData()
        #expect(!String(decoding: legacy, as: UTF8.self).contains("\"curve\""))
        var key = library.clips[0].tracks[0].keys[0]
        key.curve = .init(easing: .init(family: .quadratic, direction: .in))
        try library.apply([.init(kind: .putKey, clipID: "clip", trackID: "position", key: key, replaceExisting: true)])
        #expect(library.version == 2)
        #expect(try AnimationLibrary.decode(library.encodedData()).version == 2)
        var disguised = library
        disguised.version = 1
        #expect(throws: AnimationAuthoringError.self) { try disguised.encodedData() }
        #expect(try AnimationLibrary.decode(legacy).version == 1)
        var future = library
        future.version = 3
        #expect(throws: AnimationAuthoringError.self) { try future.validate() }
    }

    @Test
    func authoredEasingSurvivesPortableRoundTripAndDrivesTheProductionPlayer() throws {
        var library = try fixture()
        library.clips[0].tracks[0].keys[0].curve = .init(easing: .init(family: .quadratic, direction: .in))
        let reopened = try AnimationLibrary.decode(library.encodedData())
        #expect(reopened == library)
        #expect(abs(try reopened.sample(clipID: "clip", at: 0.5).poses[0].translation.x - 0.25) < 0.00001)
    }

    @Test
    func bezierVectorAndMorphTracksUseTheSameTemporalEvaluator() throws {
        var library = try fixture()
        library.clips[0].tracks[0].interpolation = .bezier
        library.clips[0].tracks[0].keys[0].curve = .init(outgoing: Array(repeating: .init(timeOffset: 0, valueOffset: 0), count: 3))
        library.clips[0].tracks[0].keys[1].curve = .init(incoming: Array(repeating: .init(timeOffset: -1, valueOffset: 0), count: 3))
        library.clips[0].tracks.append(.init(id: "morph", nodeID: "node-0", channel: .weights, interpolation: .bezier, keys: [
            .init(id: "m0", time: 0, value: [0, 2], curve: .init(outgoing: [.init(timeOffset: 0, valueOffset: 0), .init(timeOffset: 1 / 3, valueOffset: 0)])),
            .init(id: "m1", time: 1, value: [1, -1], curve: .init(incoming: [.init(timeOffset: -1, valueOffset: 0), .init(timeOffset: -1 / 3, valueOffset: 0)]))
        ]))
        let player = try? library.sample(clipID: "clip", at: 0.125)
        #expect(abs((player?.poses[0].translation.x ?? -1) - 0.5) < 0.00001)
        #expect(abs((player?.morphWeights[0][0] ?? -1) - 0.5) < 0.00001)
        #expect(abs((player?.morphWeights[0][1] ?? -1) - 1.87109375) < 0.00001)
        let clips = try? library.compiledClips(for: library.binding.makeRig())
        #expect(clips?.first?.tracks.first?.interpolation.rawValue == "bezier")
    }

    @Test
    func malformedCurveEditsAreAtomicAndQuaternionBezierIsRejected() throws {
        var library = try fixture()
        let original = library
        var key = library.clips[0].tracks[0].keys[0]
        key.curve = .init(easing: .init(period: 0))
        #expect(throws: AnimationEditError.self) {
            try library.apply([.init(kind: .putKey, clipID: "clip", trackID: "position", key: key, replaceExisting: true)])
        }
        #expect(library == original)
        var rotation = original
        rotation.clips[0].tracks = [.init(nodeID: "node-0", channel: .rotation, interpolation: .bezier, keys: [
            .init(time: 0, value: [0, 0, 0, 1]), .init(time: 1, value: [0, 0, 0, 1])
        ])]
        #expect(throws: AnimationAuthoringError.self) { try rotation.validate() }
    }

    private func fixture() throws -> AnimationLibrary {
        let pose = SkeletalJointPose()
        let rig = try SkeletalRig(nodes: [.init(parentIndex: nil, restPose: pose, restMatrix: pose.matrix, morphRestWeights: [0, 0])])
        return .init(id: "curves", binding: .init(rig: rig, sourceAsset: "Robot.glb"), clips: [
            .init(id: "clip", name: "Curve", duration: 1, repeats: false, tracks: [
                .init(id: "position", nodeID: "node-0", channel: .translation, keys: [
                    .init(id: "first", time: 0, value: [0, 0, 0]), .init(id: "last", time: 1, value: [1, 0, 0])
                ])
            ])
        ], version: 2)
    }
}
