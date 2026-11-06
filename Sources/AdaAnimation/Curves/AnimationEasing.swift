import Foundation

/// Invalid portable curve data. Editors validate before replacing an existing draft.
public enum AnimationCurveError: Error, Equatable, Sendable {
    case invalidParameters
    case invalidProgress
    case invalidSegment
    case nonMonotoneTime
}

/// A time-independent easing family, separate from key interpolation and spatial paths.
public struct AnimationEasing: Codable, Equatable, Sendable {
    public enum Family: String, CaseIterable, Codable, Sendable {
        case linear, quadratic, cubic, quartic, quintic, sine, exponential, circular, back, elastic, bounce
    }

    public enum Direction: String, CaseIterable, Codable, Sendable {
        case `in`, out, inOut, outIn
    }

    private enum CodingKeys: String, CodingKey { case family, direction, overshoot, amplitude, period }

    public var family: Family
    public var direction: Direction
    public var overshoot: Double
    public var amplitude: Double
    public var period: Double

    public init(family: Family = .linear, direction: Direction = .inOut,
                overshoot: Double = 1.70158, amplitude: Double = 1, period: Double = 0.3) {
        self.family = family
        self.direction = direction
        self.overshoot = overshoot
        self.amplitude = amplitude
        self.period = period
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(family: try values.decodeIfPresent(Family.self, forKey: .family) ?? .linear,
                  direction: try values.decodeIfPresent(Direction.self, forKey: .direction) ?? .inOut,
                  overshoot: try values.decodeIfPresent(Double.self, forKey: .overshoot) ?? 1.70158,
                  amplitude: try values.decodeIfPresent(Double.self, forKey: .amplitude) ?? 1,
                  period: try values.decodeIfPresent(Double.self, forKey: .period) ?? 0.3)
    }

    /// Parameters are bounded before compilation; unused parameters must also be valid.
    public func validate() throws(AnimationCurveError) {
        guard overshoot.isFinite, (0...8).contains(overshoot), amplitude.isFinite, (1...8).contains(amplitude),
              period.isFinite, (0.00001...4).contains(period) else { throw .invalidParameters }
    }

    /// Samples normalized progress. Input is clamped to [0, 1]; output may overshoot.
    public func sample(_ progress: Double) throws(AnimationCurveError) -> Double {
        try validate()
        guard progress.isFinite else { throw .invalidProgress }
        return evaluate(min(1, max(0, progress)))
    }

    func evaluate(_ progress: Double) -> Double {
        if family == .linear || progress == 0 || progress == 1 { return progress }
        switch direction {
        case .in: return easeIn(progress)
        case .out: return 1 - easeIn(1 - progress)
        case .inOut:
            return progress < 0.5 ? easeIn(2 * progress) / 2 : 1 - easeIn(2 * (1 - progress)) / 2
        case .outIn:
            return progress < 0.5 ? (1 - easeIn(1 - 2 * progress)) / 2 : (1 + easeIn(2 * progress - 1)) / 2
        }
    }

    var parameterRange: ClosedRange<Double> {
        switch family {
        case .back: return (-overshoot)...(1 + overshoot)
        case .elastic: return (-amplitude)...(1 + amplitude)
        default: return 0...1
        }
    }

    private func easeIn(_ progress: Double) -> Double {
        if progress == 0 || progress == 1 { return progress }
        switch family {
        case .linear: return progress
        case .quadratic: return progress * progress
        case .cubic: return progress * progress * progress
        case .quartic: return pow(progress, 4)
        case .quintic: return pow(progress, 5)
        case .sine: return 1 - cos(progress * .pi / 2)
        case .exponential: return pow(2, 10 * (progress - 1))
        case .circular: return 1 - sqrt(max(0, 1 - progress * progress))
        case .back: return progress * progress * ((overshoot + 1) * progress - overshoot)
        case .elastic:
            let phase = asin(1 / amplitude) * period / (2 * .pi)
            return -amplitude * pow(2, 10 * (progress - 1)) * sin((progress - 1 - phase) * 2 * .pi / period)
        case .bounce: return 1 - Self.bounceOut(1 - progress)
        }
    }

    private static func bounceOut(_ progress: Double) -> Double {
        let scale = 7.5625, span = 2.75
        if progress < 1 / span { return scale * progress * progress }
        if progress < 2 / span {
            let value = progress - 1.5 / span
            return scale * value * value + 0.75
        }
        if progress < 2.5 / span {
            let value = progress - 2.25 / span
            return scale * value * value + 0.9375
        }
        let value = progress - 2.625 / span
        return scale * value * value + 0.984375
    }
}
