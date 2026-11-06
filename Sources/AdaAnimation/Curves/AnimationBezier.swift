/// A temporal Bézier handle relative to its key, in seconds and value units.
/// It is not a Hermite derivative or a spatial path control point.
public struct AnimationBezierHandle: Codable, Equatable, Sendable {
    public var timeOffset: Double
    public var valueOffset: Double

    public init(timeOffset: Double, valueOffset: Double) {
        self.timeOffset = timeOffset
        self.valueOffset = valueOffset
    }
}

/// One scalar temporal segment. Endpoint/control values use the portable Float range.
/// Time is solved first; easing then remaps the Bézier parameter before sampling value.
public struct AnimationBezierSegment: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey { case startTime, endTime, startValue, endValue, outgoing, incoming, easing }

    public var startTime: Double
    public var endTime: Double
    public var startValue: Double
    public var endValue: Double
    public var outgoing: AnimationBezierHandle
    public var incoming: AnimationBezierHandle
    public var easing: AnimationEasing

    public init(startTime: Double, endTime: Double, startValue: Double, endValue: Double,
                outgoing: AnimationBezierHandle? = nil, incoming: AnimationBezierHandle? = nil,
                easing: AnimationEasing = .init()) {
        self.startTime = startTime
        self.endTime = endTime
        self.startValue = startValue
        self.endValue = endValue
        self.outgoing = outgoing ?? .init(timeOffset: (endTime - startTime) / 3, valueOffset: (endValue - startValue) / 3)
        self.incoming = incoming ?? .init(timeOffset: (startTime - endTime) / 3, valueOffset: (startValue - endValue) / 3)
        self.easing = easing
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(startTime: try values.decode(Double.self, forKey: .startTime), endTime: try values.decode(Double.self, forKey: .endTime),
                  startValue: try values.decode(Double.self, forKey: .startValue), endValue: try values.decode(Double.self, forKey: .endValue),
                  outgoing: try values.decodeIfPresent(AnimationBezierHandle.self, forKey: .outgoing),
                  incoming: try values.decodeIfPresent(AnimationBezierHandle.self, forKey: .incoming),
                  easing: try values.decodeIfPresent(AnimationEasing.self, forKey: .easing) ?? .init())
    }

    public func validate() throws(AnimationCurveError) {
        _ = try CompiledAnimationBezier(self)
    }

    /// Clamps finite time to the segment. Invalid data fails before evaluation.
    public func sample(at time: Double) throws(AnimationCurveError) -> Double {
        guard time.isFinite else { throw .invalidProgress }
        return try CompiledAnimationBezier(self).sample(at: time)
    }
}

/// Coefficients and validation are retained once by a compiled animation track.
struct CompiledAnimationBezier: Sendable {
    private let segment: AnimationBezierSegment
    private let duration: Double
    private let timeA: Double
    private let timeB: Double
    private let timeC: Double

    init(_ segment: AnimationBezierSegment) throws(AnimationCurveError) {
        let startTime = segment.startTime, endTime = segment.endTime
        let outgoing = segment.outgoing, incoming = segment.incoming
        let startValue = segment.startValue, endValue = segment.endValue
        let duration = endTime - startTime
        guard startTime.isFinite, endTime.isFinite, duration.isFinite, duration > 0,
              outgoing.timeOffset.isFinite, incoming.timeOffset.isFinite else { throw .invalidSegment }
        let values = [startValue, endValue, outgoing.valueOffset, incoming.valueOffset,
                      startValue + outgoing.valueOffset, endValue + incoming.valueOffset]
        guard values.allSatisfy({ $0.isFinite && abs($0) <= Double(Float.greatestFiniteMagnitude) }) else { throw .invalidSegment }
        try segment.easing.validate()
        let first = outgoing.timeOffset / duration, second = 1 + incoming.timeOffset / duration
        let a = 1 - 3 * second + 3 * first, b = 2 * (second - 2 * first)
        guard first.isFinite, second.isFinite, a.isFinite, b.isFinite else { throw .invalidSegment }
        // A cubic is monotone exactly when its derivative is nonnegative on [0, 1].
        // Checking the quadratic's endpoints and interior minimum also permits crossing handles.
        guard first >= 0, second <= 1 else { throw .nonMonotoneTime }
        if a > 0 {
            let minimum = -b / (2 * a)
            if minimum > 0, minimum < 1, (a * minimum + b) * minimum + first < 0 { throw .nonMonotoneTime }
        }
        self.segment = segment
        self.duration = duration
        self.timeA = a
        self.timeB = 3 * second - 6 * first
        self.timeC = 3 * first
    }

    func sample(at time: Double) -> Double {
        guard time.isFinite, time > segment.startTime else { return segment.startValue }
        if time >= segment.endTime { return segment.endValue }
        let progress = (time - segment.startTime) / duration
        let parameter = segment.easing.evaluate(parameter(at: progress))
        return value(at: parameter)
    }

    /// Rejects a curve that could overflow a Float property; the curve itself is never clamped.
    func requireFloatRange() throws(AnimationCurveError) {
        let range = segment.easing.parameterRange
        if range.lowerBound >= 0, range.upperBound <= 1 { return }
        let first = segment.startValue + segment.outgoing.valueOffset, second = segment.endValue + segment.incoming.valueOffset
        let a = -segment.startValue + 3 * first - 3 * second + segment.endValue
        let b = 3 * segment.startValue - 6 * first + 3 * second
        let c = 3 * (first - segment.startValue)
        var candidates = [range.lowerBound, range.upperBound]
        if a == 0 {
            if b != 0 { candidates.append(-c / (2 * b)) }
        } else {
            let discriminant = b * b - 3 * a * c
            if discriminant >= 0 {
                let root = discriminant.squareRoot()
                let q = -b - (b < 0 ? -root : root)
                if q == 0 { candidates.append(-b / (3 * a)) }
                else { candidates.append(q / (3 * a)); candidates.append(c / q) }
            }
        }
        for parameter in candidates where range.contains(parameter) {
            let sampled = value(at: parameter)
            guard sampled.isFinite, abs(sampled) <= Double(Float.greatestFiniteMagnitude) else { throw .invalidSegment }
        }
    }

    private func value(at parameter: Double) -> Double {
        let one = Self.interpolate(segment.startValue, segment.startValue + segment.outgoing.valueOffset, parameter)
        let two = Self.interpolate(segment.startValue + segment.outgoing.valueOffset, segment.endValue + segment.incoming.valueOffset, parameter)
        let three = Self.interpolate(segment.endValue + segment.incoming.valueOffset, segment.endValue, parameter)
        return Self.interpolate(Self.interpolate(one, two, parameter), Self.interpolate(two, three, parameter), parameter)
    }

    private func parameter(at time: Double) -> Double {
        var lower = 0.0, upper = 1.0
        // A fixed bound handles vertical/flat tangents without dividing by their derivative.
        for _ in 0..<48 {
            let middle = (lower + upper) / 2
            let value = ((timeA * middle + timeB) * middle + timeC) * middle
            if value == time { return middle }
            if value < time { lower = middle } else { upper = middle }
        }
        return (lower + upper) / 2
    }

    private static func interpolate(_ source: Double, _ target: Double, _ amount: Double) -> Double {
        source * (1 - amount) + target * amount
    }
}
