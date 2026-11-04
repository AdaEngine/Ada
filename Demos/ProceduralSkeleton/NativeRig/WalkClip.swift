import AdaAssets
import Math

/// Authored in-place walk. Two-bone leg IK maintains a flat planted foot during stance.
enum WalkClip {
    static let duration: Float = 1.2
    static let keyCount = 49

    static func make() -> ProceduralAnimation {
        let times = (0..<keyCount).map { Float($0) * duration / Float(keyCount - 1) }
        var rotations = [Joint: [SIMD4<Float>]]()
        var hips: [SIMD4<Float>] = []
        for time in times {
            // Force the final key to match the first, including floating-point rounding.
            let phase: Float = time == duration ? 0 : time / duration
            let cycle = phase * 2 * .pi
            let bob: Float = -0.025 + 0.004 * Math.cos(2 * cycle)
            hips.append(SIMD4(0, Joint.hips.local.y + bob, 0, 0))
            var pose = [Joint: SIMD3<Float>]()
            for (hip, knee, ankle, offset) in [(Joint.leftHip, Joint.leftKnee, Joint.leftAnkle, Float(0)), (.rightHip, .rightKnee, .rightAnkle, 0.5)] {
                let leg = legAngles(phase: (phase + offset).truncatingRemainder(dividingBy: 1), hipHeight: hip.position.y + bob)
                pose[hip] = [leg.x, 0, 0]
                pose[knee] = [leg.y, 0, 0]
                pose[ankle] = [leg.z, 0, 0]
            }
            pose[.spine] = [1.2 * Math.sin(2 * cycle), 2.5 * Math.sin(cycle), 0]
            pose[.chest] = [0, -4 * Math.sin(cycle), 1.8 * Math.sin(cycle)]
            pose[.head] = [0, 1.5 * Math.sin(cycle), -1.8 * Math.sin(cycle)]
            pose[.jaw] = [2 + Math.sin(2 * cycle), 0, 0]
            pose[.leftShoulder] = [-12 * Math.cos(cycle), 0, 43]
            pose[.rightShoulder] = [12 * Math.cos(cycle), 0, -43]
            pose[.leftElbow] = [-7 - 4 * Math.sin(cycle), 0, 0]
            pose[.rightElbow] = [-7 + 4 * Math.sin(cycle), 0, 0]
            // Keep the held props upright while the shoulders lower the arms from the authored bind pose.
            pose[.leftWrist] = [0, 0, -43]
            pose[.rightWrist] = [0, 0, 43]
            for (joint, angles) in pose { rotations[joint, default: []].append(ProceduralMath.quaternion(eulerDegrees: angles)) }
        }
        var tracks = [ProceduralAnimation.Track(node: Joint.hips.node, path: .translation, times: times, values: hips)]
        for joint in Joint.allCases {
            if let values = rotations[joint] { tracks.append(.init(node: joint.node, path: .rotation, times: times, values: values)) }
        }
        return ProceduralAnimation(name: "Walk", tracks: tracks)
    }

    static func bindPose() -> ProceduralAnimation {
        var tracks = Joint.allCases.map { joint in
            ProceduralAnimation.Track(node: joint.node, path: .rotation, times: [0, duration], values: [[0, 0, 0, 1], [0, 0, 0, 1]])
        }
        let p = Joint.hips.local
        tracks.append(.init(node: Joint.hips.node, path: .translation, times: [0, duration], values: [[p.x, p.y, p.z, 0], [p.x, p.y, p.z, 0]]))
        return ProceduralAnimation(name: "BindPose", tracks: tracks)
    }

    /// Frozen native-player poses for deterministic GPU frame capture, independent of screenshot/readback stalls.
    static func capturePoses() -> [ProceduralAnimation] {
        let walk = make()
        return (0..<24).map { frame in
            let tracks = walk.tracks.map { track in
                let value = track.values[frame * 2]
                return ProceduralAnimation.Track(node: track.node, path: track.path, times: [0, duration], values: [value, value])
            }
            return ProceduralAnimation(name: "CapturePose\(frame)", tracks: tracks)
        }
    }

    private static func legAngles(phase: Float, hipHeight: Float) -> SIMD3<Float> {
        let stance = phase < 0.5
        let progress = stance ? phase * 2 : (phase - 0.5) * 2
        let z: Float = stance ? -0.075 + 0.15 * progress : 0.075 - 0.15 * progress
        let lift: Float = stance ? 0 : 0.035 * Math.sin(.pi * progress)
        let dy = hipHeight - (Joint.leftAnkle.position.y + lift)
        let dz = z - 0.015
        let upper: Float = 0.08
        let lower = Math.sqrt(Float(0.14 * 0.14 + 0.015 * 0.015))
        let distance = min(Math.sqrt(dy * dy + dz * dz), upper + lower - 0.00001)
        let clamp: (Float) -> Float = { min(1, max(-1, $0)) }
        let knee = -Math.acos(clamp((distance * distance - upper * upper - lower * lower) / (2 * upper * lower)))
        let hip = Math.atan2(-dz, dy) - Math.atan2(lower * Math.sin(knee), upper + lower * Math.cos(knee))
        let restInclination = Math.atan2(Float(0.015), Float(0.14))
        return SIMD3(hip, knee - restInclination, restInclination - hip - knee) * (180 / .pi)
    }
}
