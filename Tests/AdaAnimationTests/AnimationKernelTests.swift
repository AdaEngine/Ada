import AdaAnimation
import Math
import Testing

struct AnimationKernelTests {
    @Test(arguments: [(0.0, 10.0, 100.0), (10.0, 0.0, 100.0), (3.0, 4.0, 25.0), (0.0, 0.0, 0.0)])
    func pairMagnitudeIncludesBothComponents(first: Double, second: Double, expected: Double) {
        #expect(AnimatablePair(first, second).magnitudeSquared == expected)
    }

    @MainActor
    @Test
    func rectangleDetectsPositionOnlyAndSizeOnlyChanges() {
        let original = Rect(x: 0, y: 0, width: 40, height: 40)
        let moved = Rect(x: 10, y: 0, width: 40, height: 40)
        let resized = Rect(x: 0, y: 0, width: 80, height: 40)

        #expect((moved.animatableData - original.animatableData).magnitudeSquared == 100)
        #expect((resized.animatableData - original.animatableData).magnitudeSquared == 1600)
    }

    @Test
    func delayHoldsThenRunsTheEntireBaseAnimation() {
        let animation = Animation.linear(duration: 1).delay(0.5)
        var context = AnimationContext<Double>()

        #expect(animation.base.finiteDuration == 1.5)
        #expect(animation.base.animate(10, time: 0.25, context: &context) == 0)
        #expect(animation.base.animate(10, time: 0.5, context: &context) == 0)
        #expect(animation.base.animate(10, time: 0.75, context: &context) == 2.5)
        #expect(animation.base.animate(10, time: 1, context: &context) == 5)
        #expect(animation.base.animate(10, time: 1.5, context: &context) == nil)
    }

    @Test
    func chainedDelaysAccumulate() {
        let animation = Animation.linear(duration: 1).delay(0.25).delay(0.5)
        var context = AnimationContext<Double>()

        #expect(animation.base.finiteDuration == 1.75)
        #expect(animation.base.animate(10, time: 0.5, context: &context) == 0)
        #expect(animation.base.animate(10, time: 1, context: &context) == 2.5)
        #expect(animation.base.animate(10, time: 1.75, context: &context) == nil)
    }

    @Test
    func repeatingDelayedAnimationUsesTheFullCycleDuration() {
        let animation = Animation.linear(duration: 1).delay(0.5).repeatForever(autoreverses: false)
        var context = AnimationContext<Double>()

        #expect(animation.base.finiteDuration == nil)
        #expect(animation.base.animate(10, time: 1.25, context: &context) == 7.5)
        #expect(animation.base.animate(10, time: 1.75, context: &context) == 0)
        #expect(animation.base.animate(10, time: 2.25, context: &context) == 2.5)
    }

    @Test(arguments: [Float(0), -0.5])
    func nonpositiveDelayDoesNotShiftTheBaseAnimation(delay: Float) {
        let animation = Animation.linear(duration: 1).delay(delay)
        var context = AnimationContext<Double>()

        #expect(animation.base.finiteDuration == 1)
        #expect(animation.base.animate(10, time: 0.5, context: &context) == 5)
        #expect(animation.base.animate(10, time: 1, context: &context) == nil)
    }

    @Test
    func delayVelocityIsZeroWhileWaiting() {
        let animation = Animation.linear(duration: 2).delay(0.5)
        var context = AnimationContext<Double>()

        #expect(animation.base.velocity(10, time: 0.25, context: &context) == 0)
        #expect(animation.base.velocity(10, time: 0.75, context: &context) == 5)
    }

    @Test
    func delayOutsideRepeatWaitsOnlyOnce() {
        let animation = Animation.linear(duration: 1).repeatForever(autoreverses: false).delay(0.5)
        var context = AnimationContext<Double>()

        #expect(animation.base.finiteDuration == nil)
        #expect(animation.base.animate(10, time: 0.25, context: &context) == 0)
        #expect(animation.base.animate(10, time: 1.75, context: &context) == 2.5)
    }
}
