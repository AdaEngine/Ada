import AdaAnimation
@testable import AdaPlatform
@testable import AdaUI
import AdaUtils
import Math
import Testing

@MainActor
struct AnimationRuntimeRegressionTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func widthRetargetDuringLayoutReachesTheLatestState() throws {
        let capture = AnimationWidthBinding()
        let tester = ViewTester(rootView: RetargetableWidthView(capture: capture))
            .setSize(Size(width: 300, height: 80))
            .performLayout()
        let node = try #require(tester.findNodeByAccessibilityIdentifier("animated-frame"))

        capture.width.wrappedValue = 120
        tester.advanceFrame(deltaTime: 0)
        tester.advanceFrame(deltaTime: 0.25)
        #expect(abs(node.frame.width - 60) < 0.01)

        capture.width.wrappedValue = 200
        tester.advanceFrame(deltaTime: 0)
        tester.advanceFrame(deltaTime: 0.5)
        #expect(abs(node.frame.width - 130) < 0.01)
        tester.advanceFrame(deltaTime: 0.5)
        #expect(abs(node.frame.width - 200) < 0.01)

        tester.advanceFrame(deltaTime: 1)
        #expect(abs(node.frame.width - 200) < 0.01)
    }

    @Test
    func delayedOpacityHoldsBeforeFadingInTheMountedTree() throws {
        let capture = AnimationOpacityBinding()
        let tester = ViewTester(rootView: DelayedOpacityView(capture: capture))
            .setSize(Size(width: 100, height: 100))
            .performLayout()
        let node = try #require(tester.findNodeByAccessibilityIdentifier("delayed-opacity") as? OpacityViewNodeModifier)

        capture.hidden.wrappedValue = true
        tester.advanceFrame(deltaTime: 0.25)
        #expect(node.opacity == 1)
        tester.advanceFrame(deltaTime: 0.25)
        #expect(node.opacity == 1)
        tester.advanceFrame(deltaTime: 0.25)
        #expect(abs(node.opacity - 0.75) < 0.01)
        tester.advanceFrame(deltaTime: 0.75)
        #expect(node.opacity == 0)
    }
}

@MainActor
private final class AnimationWidthBinding {
    var width: Binding<Float> = .constant(40)
}

private struct RetargetableWidthView: View {
    let capture: AnimationWidthBinding
    @State private var width: Float = 40

    var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = capture.width = $width
        Color.red
            .frame(width: width, height: 40)
            .accessibilityIdentifier("animated-frame")
            .animation(.linear(duration: 1), value: width)
            .frame(width: 300, height: 80, alignment: .leading)
    }
}

@MainActor
private final class AnimationOpacityBinding {
    var hidden: Binding<Bool> = .constant(false)
}

private struct DelayedOpacityView: View {
    let capture: AnimationOpacityBinding
    @State private var hidden = false

    var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = capture.hidden = $hidden
        Color.red
            .frame(width: 40, height: 40)
            .opacity(hidden ? 0 : 1)
            .accessibilityIdentifier("delayed-opacity")
            .animation(.linear(duration: 1).delay(0.5), value: hidden)
    }
}
