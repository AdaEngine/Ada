import Foundation

/// A validated glTF-style track of morph target weights for one node: `targetCount` weights per key.
///
/// Cubic keys store the in-tangents, the values and the out-tangents of every target, in that order.
public struct MorphWeightsTrack: Sendable {
    public let nodeIndex: Int
    public let interpolation: SkeletalAnimationTrack.Interpolation
    public let times: [Double]
    public let targetCount: Int
    /// `times.count * targetCount` values, or three times that for cubic keys.
    public let values: [Float]
    var authoredCurves: CompiledAnimationCurves?
    /// Native key metadata, preserved when a compiled clip is extracted for editing.
    public var keyCurves: [AnimationKeyCurve?]? { authoredCurves?.metadata }

    public init(
        nodeIndex: Int,
        interpolation: SkeletalAnimationTrack.Interpolation,
        times: [Double],
        targetCount: Int,
        values: [Float]
    ) throws(SkeletalAnimationError) {
        let multiplier = interpolation == .cubicSpline ? 3 : 1
        guard nodeIndex >= 0, targetCount > 0, !times.isEmpty, times.allSatisfy({ $0.isFinite && $0 >= 0 }),
            zip(times, times.dropFirst()).allSatisfy({ $0 < $1 }),
            values.count == times.count * targetCount * multiplier, values.allSatisfy(\.isFinite),
            interpolation != .cubicSpline || times.count >= 2
        else { throw .invalidTrack }
        self.nodeIndex = nodeIndex
        self.interpolation = interpolation
        self.times = times
        self.targetCount = targetCount
        self.values = values
    }

    /// Writes the weights at `time` into `output` (which must hold `targetCount` values) without allocating.
    public func sample(at time: Double, into output: inout [Float]) {
        guard output.count >= targetCount else { return }
        guard time.isFinite, time > times[0] else {
            for target in 0..<targetCount { output[target] = value(key: 0, target: target) }
            return
        }
        let last = times.count - 1
        guard time < times[last] else {
            for target in 0..<targetCount { output[target] = value(key: last, target: target) }
            return
        }
        var lower = 0
        var upper = last
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if times[middle] <= time { lower = middle } else { upper = middle }
        }
        if let curves = authoredCurves, curves.requiresSampling, curves.hasCustomSegment(lower) {
            for target in 0..<targetCount { output[target] = Float(curves.sample(at: time, lower: lower, component: target)) }
            return
        }
        let span = Float(times[upper] - times[lower])
        let amount = Float((time - times[lower]) / (times[upper] - times[lower]))
        let squared = amount * amount
        let cubed = squared * amount
        for target in 0..<targetCount {
            let start = value(key: lower, target: target)
            switch interpolation {
            case .step:
                output[target] = start
            case .linear, .bezier:
                output[target] = start + (value(key: upper, target: target) - start) * amount
            case .cubicSpline:
                let end = value(key: upper, target: target)
                let outgoing = values[(lower * 3 + 2) * targetCount + target] * span
                let incoming = values[(upper * 3) * targetCount + target] * span
                output[target] = start * (2 * cubed - 3 * squared + 1)
                    + outgoing * (cubed - 2 * squared + amount)
                    + end * (-2 * cubed + 3 * squared)
                    + incoming * (cubed - squared)
            }
        }
    }

    private func value(key: Int, target: Int) -> Float {
        interpolation == .cubicSpline ? values[(key * 3 + 1) * targetCount + target] : values[key * targetCount + target]
    }
}
