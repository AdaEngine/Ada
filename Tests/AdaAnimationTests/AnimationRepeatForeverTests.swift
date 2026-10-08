//
//  AnimationRepeatForeverTests.swift
//

import AdaAnimation
import AdaUtils
import Testing

struct AnimationRepeatForeverTests {

    @Test
    func repeatForeverLoopsFiniteAnimation() {
        let animation = Animation.linear(duration: 1).repeatForever(autoreverses: false)
        var context = AnimationContext<Double>()

        let firstHalf = animation.base.animate(10, time: 0.5, context: &context)
        let secondLoopQuarter = animation.base.animate(10, time: 1.25, context: &context)
        let exactBoundary = animation.base.animate(10, time: 2, context: &context)

        #expect(abs((firstHalf ?? -1) - 5) < 0.001)
        #expect(abs((secondLoopQuarter ?? -1) - 2.5) < 0.001)
        #expect(abs((exactBoundary ?? -1) - 0) < 0.001)
    }

    @Test
    func repeatForeverAutoreversesOddCycles() {
        let animation = Animation.linear(duration: 1).repeatForever(autoreverses: true)
        var context = AnimationContext<Double>()

        let forwardHalf = animation.base.animate(10, time: 0.5, context: &context)
        let reverseQuarter = animation.base.animate(10, time: 1.25, context: &context)
        let reverseHalf = animation.base.animate(10, time: 1.5, context: &context)
        let nextForwardQuarter = animation.base.animate(10, time: 2.25, context: &context)

        #expect(abs((forwardHalf ?? -1) - 5) < 0.001)
        #expect(abs((reverseQuarter ?? -1) - 7.5) < 0.001)
        #expect(abs((reverseHalf ?? -1) - 5) < 0.001)
        #expect(abs((nextForwardQuarter ?? -1) - 2.5) < 0.001)
    }
}
