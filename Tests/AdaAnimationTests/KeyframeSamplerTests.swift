//
//  KeyframeSamplerTests.swift
//

import AdaAnimation
import AdaUtils
import Math
import Testing

struct KeyframeSamplerTests {

    @Test
    func sampleVectorArithmetic_linearMidpoint() {
        let keys: [(time: TimeInterval, value: Vector3, curveToNext: KeyframeCurveKind)] = [
            (time: 0, value: Vector3(0, 0, 0), curveToNext: .linear),
            (time: 1, value: Vector3(10, 0, 0), curveToNext: .linear)
        ]
        let v = sampleVectorArithmetic(keyframes: keys, localTime: 0.5)
        #expect(v != nil)
        #expect(abs(Double(v!.x) - 5) < 0.001)
    }

    // Backward-compat: sampleVector3Keyframes still works.
    @Test
    func sampleVector3Keyframes_midpoint() {
        let keys = [
            Vector3Keyframe(time: 0, value: Vector3(0, 0, 0), curveToNext: .linear),
            Vector3Keyframe(time: 1, value: Vector3(10, 0, 0), curveToNext: .linear)
        ]
        let v = sampleVector3Keyframes(keys, localTime: 0.5)
        #expect(v != nil)
        #expect(abs(Double(v!.x) - 5) < 0.001)
    }

    @Test
    func normalizedTime_loopWraps() {
        let t = keyframeNormalizedLocalTime(playhead: 2.5, duration: 1, mode: .loop())
        #expect(abs(Double(t) - 0.5) < 0.001)
    }

    @Test
    func normalizedTime_pingPong() {
        let t = keyframeNormalizedLocalTime(playhead: 1.5, duration: 1, mode: .pingPong)
        #expect(abs(Double(t) - 0.5) < 0.001)
    }

    @Test
    func normalizedTime_loopReversed() {
        // forward loop at 0.25 → 0.25; reversed loop at 0.25 → 1.0 - 0.25 = 0.75
        let fwd = keyframeNormalizedLocalTime(playhead: 0.25, duration: 1, mode: .loop(reversed: false))
        #expect(abs(Double(fwd) - 0.25) < 0.001)
        let rev = keyframeNormalizedLocalTime(playhead: 0.25, duration: 1, mode: .loop(reversed: true))
        #expect(abs(Double(rev) - 0.75) < 0.001)
    }

    @Test
    func playbackState_repeatCountCompletes() {
        let running = keyframePlaybackState(playhead: 1.2, duration: 1, mode: .repeatCount(2))
        #expect(running.isFinished == false)
        #expect(abs(Double(running.localTime) - 0.2) < 0.001)

        let done = keyframePlaybackState(playhead: 2.0, duration: 1, mode: .repeatCount(2))
        #expect(done.isFinished == true)
        #expect(abs(Double(done.localTime) - 1.0) < 0.001)
    }
}
