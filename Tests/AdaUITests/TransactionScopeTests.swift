import AdaAnimation
@testable import AdaPlatform
@testable import AdaUI
import AdaUtils
import Math
import Observation
import Testing

@MainActor
struct TransactionScopeTests {
    init() async throws { try Application.prepareForTest() }

    @Test
    func unchangedAnimationValueDoesNotFreezeOtherState() throws {
        let capture = TransactionBindings()
        let tester = ViewTester(rootView: TransactionProbe(capture: capture))
            .setSize(Size(width: 100, height: 100)).performLayout()
        let node = try #require(tester.findNodeByAccessibilityIdentifier("opacity") as? OpacityViewNodeModifier)
        capture.opacity.wrappedValue = 0.25
        #expect(node.opacity == 0.25)
        tester.advanceFrame(deltaTime: 1)
        #expect(node.opacity == 0.25)
    }

    @Test
    func inheritedAnimationWorksWhenImplicitValueIsUnchangedAndNilCancelsIt() throws {
        let capture = TransactionBindings()
        let tester = ViewTester(rootView: TransactionProbe(capture: capture))
            .setSize(Size(width: 100, height: 100)).performLayout()
        let node = try #require(tester.findNodeByAccessibilityIdentifier("opacity") as? OpacityViewNodeModifier)
        withAnimation(.linear(duration: 2)) { capture.opacity.wrappedValue = 0 }
        tester.advanceFrame(deltaTime: 0.5)
        #expect(abs(node.opacity - 0.75) < 0.01)
        withAnimation(nil) { capture.opacity.wrappedValue = 1 }
        #expect(node.opacity == 1)
        tester.advanceFrame(deltaTime: 1)
        #expect(node.opacity == 1)
    }

    @Test
    func disabledTransactionPreventsImplicitAnimation() throws {
        let capture = TransactionBindings()
        let tester = ViewTester(rootView: TransactionProbe(capture: capture))
            .setSize(Size(width: 100, height: 100)).performLayout()
        let node = try #require(tester.findNodeByAccessibilityIdentifier("opacity") as? OpacityViewNodeModifier)
        var transaction = Transaction(animation: .linear(duration: 1))
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            capture.trigger.wrappedValue = true
            capture.opacity.wrappedValue = 0
        }
        #expect(node.opacity == 0)
        tester.advanceFrame(deltaTime: 0.5)
        #expect(node.opacity == 0)
    }

    @Test
    func unchangedAnimationValueDoesNotFreezeLayoutAndPlainRetargetCancelsIt() throws {
        let capture = TransactionBindings()
        let tester = ViewTester(rootView: TransactionProbe(capture: capture))
            .setSize(Size(width: 300, height: 100)).performLayout()
        let node = try #require(tester.findNodeByAccessibilityIdentifier("sized-frame"))
        capture.width.wrappedValue = 120
        tester.advanceFrame(deltaTime: 0)
        #expect(node.frame.width == 120)
        withAnimation(.linear(duration: 1)) { capture.width.wrappedValue = 200 }
        tester.advanceFrame(deltaTime: 0)
        tester.advanceFrame(deltaTime: 0.25)
        #expect(node.frame.width > 120 && node.frame.width < 200)
        capture.width.wrappedValue = 40
        tester.advanceFrame(deltaTime: 0)
        #expect(node.frame.width == 40)
        tester.advanceFrame(deltaTime: 1)
        #expect(node.frame.width == 40)
    }

    @Test
    func transactionModifierControlsTheSubtree() throws {
        let capture = TransactionBindings()
        let tester = ViewTester {
            TransactionProbe(capture: capture).transaction { $0.animation = .linear(duration: 2) }
        }.setSize(Size(width: 100, height: 100)).performLayout()
        let node = try #require(tester.findNodeByAccessibilityIdentifier("opacity") as? OpacityViewNodeModifier)
        capture.opacity.wrappedValue = 0
        tester.advanceFrame(deltaTime: 0.5)
        #expect(abs(node.opacity - 0.75) < 0.01)
    }

    @Test
    func observationCarriesTheMutationTransactionToDeferredRebuild() async throws {
        let model = ObservedAnimationState()
        let tester = ViewTester(rootView: ObservedAnimationProbe(model: model))
            .setSize(Size(width: 100, height: 100)).performLayout()
        let node = try #require(tester.findNodeByAccessibilityIdentifier("observed-opacity") as? OpacityViewNodeModifier)
        withAnimation(.linear(duration: 1)) { model.opacity = 0 }
        for _ in 0..<20 { await Task.yield() }
        #expect(node.opacity == 1)
        tester.advanceFrame(deltaTime: 0.5)
        #expect(abs(node.opacity - 0.5) < 0.01)
        tester.advanceFrame(deltaTime: 0.5)
        #expect(node.opacity == 0)
    }

    @Test
    func aTaskStartedInsideWithAnimationDoesNotInheritAnExpiredTransaction() async {
        let task = withAnimation(.linear(duration: 1)) {
            Task { @MainActor in UITransactionContext.current != nil }
        }
        #expect(await task.value == false)
        #expect(UITransactionContext.current == nil)
    }
}

@MainActor
private final class TransactionBindings {
    var opacity: Binding<Float> = .constant(1)
    var trigger: Binding<Bool> = .constant(false)
    var width: Binding<Float> = .constant(40)
}

private struct TransactionProbe: View {
    let capture: TransactionBindings
    @State private var opacity: Float = 1
    @State private var trigger = false
    @State private var width: Float = 40
    var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = capture.opacity = $opacity
        // swiftlint:disable:next redundant_discardable_let
        let _ = capture.trigger = $trigger
        // swiftlint:disable:next redundant_discardable_let
        let _ = capture.width = $width
        Color.red.frame(width: width, height: 40).accessibilityIdentifier("sized-frame")
            .opacity(opacity).accessibilityIdentifier("opacity")
            .animation(.linear(duration: 1), value: trigger)
    }
}

@Observable @MainActor
private final class ObservedAnimationState {
    var opacity: Float = 1
}

private struct ObservedAnimationProbe: View {
    let model: ObservedAnimationState
    var body: some View {
        Color.red.frame(width: 40, height: 40)
            .opacity(model.opacity).accessibilityIdentifier("observed-opacity")
    }
}
