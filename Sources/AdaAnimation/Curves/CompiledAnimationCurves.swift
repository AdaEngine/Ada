/// Optional native sampling data. Legacy/imported tracks without curve metadata retain their original evaluator.
struct CompiledAnimationCurves: Sendable {
    let interpolation: AnimationLibraryTrack.Interpolation
    let metadata: [AnimationKeyCurve?]
    let requiresSampling: Bool
    private let times: [Double]
    private let easing: [AnimationEasing]
    private let segments: [CompiledAnimationBezier]
    private let offsets: [Int]

    static func componentCount(for track: AnimationLibraryTrack, width: Int) -> Int {
        guard track.interpolation != .step, track.keys.count > 1 else { return 0 }
        if track.interpolation == .bezier { return (track.keys.count - 1) * width }
        return track.keys.dropLast().reduce(0) { $0 + (($1.curve?.easing?.family ?? .linear) == .linear ? 0 : width) }
    }

    static func make(_ track: AnimationLibraryTrack, width: Int) throws(AnimationCurveError) -> Self? {
        guard track.interpolation == .bezier || track.keys.contains(where: { $0.curve != nil }) else { return nil }
        return try Self(track, width: width)
    }

    private init(_ track: AnimationLibraryTrack, width: Int) throws(AnimationCurveError) {
        let rotation = track.channel == .rotation
        guard width > 0, !(rotation && track.interpolation == .bezier),
              Self.componentCount(for: track, width: width) <= AnimationLibrary.maximumCurveComponents else { throw .invalidSegment }
        for key in track.keys {
            guard key.value.count == width else { throw .invalidSegment }
            if let value = key.curve {
                try value.easing?.validate()
                for handles in [value.incoming, value.outgoing] {
                    guard let handles else { continue }
                    guard !rotation, handles.count == width,
                          handles.allSatisfy({ $0.timeOffset.isFinite && $0.valueOffset.isFinite && abs($0.valueOffset) <= Double(Float.greatestFiniteMagnitude) }) else {
                        throw .invalidSegment
                    }
                }
            }
        }
        self.interpolation = track.interpolation
        self.metadata = track.keys.map(\.curve)
        self.times = track.keys.map(\.time)
        self.easing = track.keys.map { $0.curve?.easing ?? .init() }
        self.requiresSampling = Self.componentCount(for: track, width: width) > 0
        if !requiresSampling || rotation && track.interpolation == .linear { self.segments = []; self.offsets = []; return }
        var segments: [CompiledAnimationBezier] = []
        var offsets = Array(repeating: -1, count: track.keys.count - 1)
        segments.reserveCapacity(Self.componentCount(for: track, width: width))
        for index in 0..<(track.keys.count - 1) {
            if track.interpolation != .bezier, easing[index].family == .linear { continue }
            offsets[index] = segments.count
            let source = track.keys[index], target = track.keys[index + 1]
            let duration = target.time - source.time
            for component in 0..<width {
                let start = Double(source.value[component]), end = Double(target.value[component])
                let outgoing: AnimationBezierHandle?, incoming: AnimationBezierHandle?
                if track.interpolation == .bezier {
                    outgoing = source.curve?.outgoing?[component]
                    incoming = target.curve?.incoming?[component]
                } else if track.interpolation == .cubicSpline {
                    guard source.outgoing?.count == width, target.incoming?.count == width else { throw .invalidSegment }
                    outgoing = .init(timeOffset: duration / 3, valueOffset: Double(source.outgoing?[component] ?? 0) * duration / 3)
                    incoming = .init(timeOffset: -duration / 3, valueOffset: -Double(target.incoming?[component] ?? 0) * duration / 3)
                } else { outgoing = nil; incoming = nil }
                let segment = try CompiledAnimationBezier(.init(startTime: source.time, endTime: target.time, startValue: start, endValue: end,
                                                               outgoing: outgoing, incoming: incoming, easing: easing[index]))
                if !rotation { try segment.requireFloatRange() }
                segments.append(segment)
            }
        }
        self.segments = segments
        self.offsets = offsets
    }

    func hasCustomSegment(_ lower: Int) -> Bool {
        interpolation != .step && (interpolation == .bezier || easing[lower].family != .linear)
    }

    func amount(at time: Double, lower: Int) -> Double {
        easing[lower].evaluate((time - times[lower]) / (times[lower + 1] - times[lower]))
    }

    func sample(at time: Double, lower: Int, component: Int) -> Double {
        segments[offsets[lower] + component].sample(at: time)
    }
}
