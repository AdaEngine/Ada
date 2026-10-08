import AdaAnimation
@testable import AdaUI
import AdaUtils
import Math
import Testing

@MainActor
struct UIAnimationControllerTests {
    @Test
    func emptyControllerStopsOnItsNextUpdate() {
        let controller = UIAnimationController(animation: .linear(duration: 1))
        controller.playAnimation()
        controller.update(0)
        #expect(!controller.isPlaying)
    }

    @Test
    func animationCanBeRegisteredAfterPlayBeforeTheFirstUpdate() {
        let controller = UIAnimationController(animation: .linear(duration: 1))
        controller.playAnimation()
        var value = 0.0
        controller.addTweenAnimation(from: TweenValue(animatableData: 0.0), to: TweenValue(animatableData: 10.0), label: "value", environment: EnvironmentValues()) {
            value = $0.animatableData
        }
        controller.update(0.5)
        #expect(value == 5)
        #expect(controller.isPlaying)
        controller.update(0.5)
        #expect(value == 10)
        #expect(!controller.isPlaying)
    }

    @Test
    func sizeOnlyRetargetReachesTheNewFrame() {
        let controller = UIAnimationController(animation: .linear(duration: 1))
        var frame = Rect(x: 0, y: 0, width: 40, height: 40)
        controller.addTweenAnimation(from: frame, to: Rect(x: 0, y: 0, width: 120, height: 40), label: "frame", environment: EnvironmentValues()) {
            frame = $0
        }
        controller.playAnimation()
        controller.update(0.25)
        #expect(frame.width == 60)

        controller.addTweenAnimation(from: frame, to: Rect(x: 0, y: 0, width: 200, height: 40), label: "frame", environment: EnvironmentValues()) {
            frame = $0
        }
        controller.update(0.5)
        #expect(frame.width == 130)
        controller.update(0.5)
        #expect(frame.width == 200)
        #expect(!controller.isPlaying)
    }

    @Test(arguments: [0.25, 1.0])
    func callbackRetargetSurvivesTheCurrentUpdate(firstDelta: Double) {
        let controller = UIAnimationController(animation: .linear(duration: 1))
        var value = 0.0
        var didRetarget = false
        controller.addTweenAnimation(from: TweenValue(animatableData: 0.0), to: TweenValue(animatableData: 10.0), label: "value", environment: EnvironmentValues()) { sample in
            value = sample.animatableData
            guard !didRetarget else {
                return
            }
            didRetarget = true
            controller.addTweenAnimation(from: sample, to: TweenValue(animatableData: 20.0), label: "value", environment: EnvironmentValues()) {
                value = $0.animatableData
            }
        }
        controller.playAnimation()
        controller.update(Float(firstDelta))
        #expect(controller.isPlaying)
        #expect(value == firstDelta * 10)
        controller.update(1)
        #expect(value == 20)
        #expect(!controller.isPlaying)
    }

    @Test
    func animationDiscoveredByLayoutCallbackReceivesTheCurrentTick() {
        let controller = UIAnimationController(animation: .linear(duration: 1))
        var secondValue = 0.0
        controller.addTweenAnimation(from: TweenValue(animatableData: 0.0), to: TweenValue(animatableData: 10.0), label: "first", environment: EnvironmentValues()) { _ in
            controller.addTweenAnimation(from: TweenValue(animatableData: 0.0), to: TweenValue(animatableData: 20.0), label: "second", environment: EnvironmentValues()) {
                secondValue = $0.animatableData
            }
        }
        controller.playAnimation()
        controller.update(0.5)
        #expect(secondValue == 10)
        #expect(controller.isPlaying)
        controller.update(0.5)
        #expect(secondValue == 20)
        #expect(!controller.isPlaying)
    }

    @Test
    func registeringTheSameTargetDoesNotRestartAnimation() {
        let controller = UIAnimationController(animation: .linear(duration: 1))
        var value = 0.0
        controller.addTweenAnimation(from: TweenValue(animatableData: value), to: TweenValue(animatableData: 10.0), label: "value", environment: EnvironmentValues()) {
            value = $0.animatableData
        }
        controller.playAnimation()
        controller.update(0.5)
        controller.addTweenAnimation(from: TweenValue(animatableData: value), to: TweenValue(animatableData: 10.0), label: "value", environment: EnvironmentValues()) {
            value = $0.animatableData
        }
        controller.update(0.5)
        #expect(value == 10)
        #expect(!controller.isPlaying)
    }

    @Test
    func callbackRetargetOfAnUpcomingEntryReceivesTheCurrentTick() {
        let controller = UIAnimationController(animation: .linear(duration: 1))
        var value = 0.0
        controller.addTweenAnimation(from: TweenValue(animatableData: 0.0), to: TweenValue(animatableData: 1.0), label: "first", environment: EnvironmentValues()) { _ in
            controller.addTweenAnimation(from: TweenValue(animatableData: value), to: TweenValue(animatableData: 20.0), label: "second", environment: EnvironmentValues()) {
                value = $0.animatableData
            }
        }
        controller.addTweenAnimation(from: TweenValue(animatableData: 0.0), to: TweenValue(animatableData: 10.0), label: "second", environment: EnvironmentValues()) {
            value = $0.animatableData
        }
        controller.playAnimation()
        controller.update(0.5)
        #expect(value == 10)
        controller.update(0.5)
        #expect(value == 20)
        #expect(!controller.isPlaying)
    }

    @Test
    func recursiveUpdateDoesNotAdvanceTimeTwice() {
        let controller = UIAnimationController(animation: .linear(duration: 1))
        var value = 0.0
        controller.addTweenAnimation(from: TweenValue(animatableData: 0.0), to: TweenValue(animatableData: 10.0), label: "value", environment: EnvironmentValues()) {
            value = $0.animatableData
            controller.update(0.5)
        }
        controller.playAnimation()
        controller.update(0.5)
        #expect(value == 5)
        controller.update(0.5)
        #expect(value == 10)
        #expect(!controller.isPlaying)
    }

    @Test
    func mergedRetargetUsesTheLatestCallback() {
        let controller = UIAnimationController(animation: Animation(MergingLinearAnimation()))
        var originalValue = 0.0
        var replacementValue = 0.0
        controller.addTweenAnimation(from: TweenValue(animatableData: 0.0), to: TweenValue(animatableData: 10.0), label: "value", environment: EnvironmentValues()) {
            originalValue = $0.animatableData
        }
        controller.playAnimation()
        controller.update(0.5)
        controller.addTweenAnimation(from: TweenValue(animatableData: originalValue), to: TweenValue(animatableData: 20.0), label: "value", environment: EnvironmentValues()) {
            replacementValue = $0.animatableData
        }
        controller.update(1)
        #expect(originalValue == 5)
        #expect(replacementValue == 20)
        #expect(!controller.isPlaying)
    }
}

private struct MergingLinearAnimation: CustomAnimation {
    func animate<V: VectorArithmetic>(_ value: V, time: Float, context: inout AnimationContext<V>) -> V? {
        Animation.linear(duration: 1).base.animate(value, time: time, context: &context)
    }

    func shouldMerge<V: VectorArithmetic>(previous: Animation, value: V, time: Float, context: inout AnimationContext<V>) -> Bool {
        true
    }
}
