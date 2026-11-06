import AdaAnimation
import Foundation
import Testing

@Suite
struct AnimationCurveTests {
    @Test
    func portableCurvePayloadsUseDefaultsForOmittedOptionalSettings() throws {
        let easing = try? JSONDecoder().decode(AnimationEasing.self, from: Data(#"{"family":"quadratic","direction":"in"}"#.utf8))
        #expect(easing?.overshoot == 1.70158)
        #expect(try easing?.sample(0.5) == 0.25)
        let segment = try? JSONDecoder().decode(AnimationBezierSegment.self,
            from: Data(#"{"startTime":0,"endTime":1,"startValue":0,"endValue":2}"#.utf8))
        #expect(segment != nil)
        #expect(abs((try segment?.sample(at: 0.25) ?? -1) - 0.5) < 1e-10)
        if let segment {
            #expect(try JSONDecoder().decode(AnimationBezierSegment.self, from: JSONEncoder().encode(segment)) == segment)
        }
    }

    @Test
    func polynomialEasingUsesNamedFamiliesAndDirections() throws {
        #expect(try AnimationEasing(family: .quadratic, direction: .in).sample(0.5) == 0.25)
        #expect(try AnimationEasing(family: .quadratic, direction: .out).sample(0.25) == 0.4375)
        #expect(try AnimationEasing(family: .quadratic, direction: .inOut).sample(0.25) == 0.125)
        #expect(try AnimationEasing(family: .quadratic, direction: .outIn).sample(0.25) == 0.375)
        #expect(try AnimationEasing(family: .cubic, direction: .in).sample(0.5) == 0.125)
        #expect(try AnimationEasing(family: .quartic, direction: .in).sample(0.5) == 0.0625)
        #expect(try AnimationEasing(family: .quintic, direction: .in).sample(0.5) == 0.03125)
    }

    @Test
    func nonPolynomialFamiliesHaveDistinctShapesAndRetainOvershoot() throws {
        #expect(abs(try AnimationEasing(family: .sine, direction: .in).sample(0.5) - 0.2928932188134524) < 1e-12)
        #expect(try AnimationEasing(family: .exponential, direction: .in).sample(0.5) == 0.03125)
        #expect(abs(try AnimationEasing(family: .circular, direction: .in).sample(0.5) - 0.1339745962155614) < 1e-12)
        #expect(try AnimationEasing(family: .back, direction: .in).sample(0.5) < 0)
        #expect(try AnimationEasing(family: .elastic, direction: .out).sample(0.2) > 1)
        #expect(abs(try AnimationEasing(family: .bounce, direction: .out).sample(0.5) - 0.765625) < 1e-12)
        let bounce = AnimationEasing(family: .bounce, direction: .out)
        #expect(try bounce.sample(0.4) > bounce.sample(0.5))
        let back = AnimationEasing(family: .back, direction: .in, overshoot: 3)
        #expect(try back.sample(0.5) == -0.25)
        let elastic = AnimationEasing(family: .elastic, direction: .out, period: 0.6)
        #expect(abs(try elastic.sample(0.25) - AnimationEasing(family: .elastic, direction: .out).sample(0.25)) > 0.1)
    }

    @Test
    func easingEndpointsAreExactAndInvalidParametersAreRejected() throws {
        for family in AnimationEasing.Family.allCases {
            for direction in AnimationEasing.Direction.allCases {
                let easing = AnimationEasing(family: family, direction: direction)
                #expect(try easing.sample(-1) == 0)
                #expect(try easing.sample(0) == 0)
                #expect(try easing.sample(1) == 1)
                #expect(try easing.sample(2) == 1)
                for index in 1..<100 { #expect(try easing.sample(Double(index) / 100).isFinite) }
            }
        }
        #expect(throws: AnimationCurveError.invalidProgress) { try AnimationEasing().sample(.nan) }
        #expect(throws: AnimationCurveError.invalidParameters) { try AnimationEasing(period: 0).sample(0.5) }
        #expect(throws: AnimationCurveError.invalidParameters) { try AnimationEasing(amplitude: .infinity).validate() }
        #expect(throws: AnimationCurveError.invalidParameters) { try AnimationEasing(overshoot: -1).validate() }
    }

    @Test
    func bezierInvertsTimeBeforeSamplingValueAndEasing() throws {
        let segment = AnimationBezierSegment(startTime: 2, endTime: 6, startValue: 0, endValue: 1,
            outgoing: .init(timeOffset: 0, valueOffset: 0), incoming: .init(timeOffset: -4, valueOffset: 0))
        #expect(abs(try segment.sample(at: 2.5) - 0.5) < 1e-10)
        var eased = segment
        eased.easing = .init(family: .quadratic, direction: .in)
        #expect(abs(try eased.sample(at: 2.5) - 0.15625) < 1e-10)
        let linear = AnimationBezierSegment(startTime: 2, endTime: 6, startValue: -3, endValue: 5)
        #expect(abs(try linear.sample(at: 3) - -1) < 1e-10)
        #expect(try segment.sample(at: -100) == 0)
        #expect(try segment.sample(at: 100) == 1)
    }

    @Test
    func bezierAcceptsMonotoneCrossingHandlesAndRejectsTimeReversal() throws {
        let flat = AnimationBezierSegment(startTime: 0, endTime: 1, startValue: 0, endValue: 1,
            outgoing: .init(timeOffset: 1, valueOffset: 0), incoming: .init(timeOffset: -1, valueOffset: 0))
        #expect(abs(try flat.sample(at: 0.500000004) - 0.501499998) < 1e-7)
        let outside = AnimationBezierSegment(startTime: 0, endTime: 1, startValue: 0, endValue: 1,
            outgoing: .init(timeOffset: 1.1, valueOffset: 0), incoming: .init(timeOffset: -0.1, valueOffset: 0))
        try outside.validate()
        var previous = -1.0
        for index in 0...20 {
            let value = try outside.sample(at: Double(index) / 20)
            #expect(value >= previous)
            previous = value
        }
        var reversed = flat
        reversed.outgoing.timeOffset = 2
        reversed.incoming.timeOffset = -2
        #expect(throws: AnimationCurveError.nonMonotoneTime) { try reversed.validate() }
        reversed = flat
        reversed.endTime = reversed.startTime
        #expect(throws: AnimationCurveError.invalidSegment) { try reversed.sample(at: 0) }
    }
}
