import AdaAnimation
@testable import AdaPlatform
@testable import AdaUI
import AdaUtils
import Math
import Testing

@MainActor
@Suite(.serialized)
struct StateUpdateBatchTests {
    init() async throws { try Application.prepareForTest() }

    @Test
    func transactionRebuildsOnceWithFinalValuesAndRetainsNodes() throws {
        let capture = BatchProbeCapture()
        let tester = ViewTester { BatchProbe(capture: capture) }
            .setSize(Size(width: 300, height: 100)).performLayout()
        let original = try #require(tester.findNodeByAccessibilityIdentifier("batch-frame"))
        let opacity = try #require(tester.findNodeByAccessibilityIdentifier("batch-opacity") as? OpacityViewNodeModifier)
        capture.builds = 0

        withTransaction(Transaction()) {
            capture.width.wrappedValue = 80
            capture.opacity.wrappedValue = 0.5
            capture.width.wrappedValue = 120
            #expect(capture.width.wrappedValue == 120)
            #expect(capture.builds == 0)
        }

        #expect(capture.builds == 1)
        #expect(opacity.opacity == 0.5)
        tester.performLayout()
        #expect(original.frame.width == 120)
        #expect(tester.findNodeByAccessibilityIdentifier("batch-frame") === original)
        capture.width.wrappedValue = 100
        #expect(capture.builds == 2) // Plain writes remain synchronous.
    }

    @Test
    func animationBatchesValuesWithoutLosingInterpolationOrPlainRetarget() throws {
        let capture = BatchProbeCapture()
        let tester = ViewTester { BatchProbe(capture: capture) }
            .setSize(Size(width: 300, height: 100)).performLayout()
        let opacity = try #require(tester.findNodeByAccessibilityIdentifier("batch-opacity") as? OpacityViewNodeModifier)
        capture.builds = 0

        withAnimation(.linear(duration: 1)) {
            capture.width.wrappedValue = 120
            capture.opacity.wrappedValue = 0
        }
        #expect(capture.builds == 1)
        tester.advanceFrame(deltaTime: 0).advanceFrame(deltaTime: 0.5)
        #expect(abs(opacity.opacity - 0.5) < 0.01)

        withTransaction(Transaction()) {
            capture.width.wrappedValue = 60
            capture.opacity.wrappedValue = 0.8
        }
        #expect(opacity.opacity == 0.8)
        tester.advanceFrame(deltaTime: 1)
        #expect(opacity.opacity == 0.8)
    }

    @Test
    func nestedPoliciesFlushInOrderAndThrowingScopeDoesNotLeavePendingWork() throws {
        let capture = BatchProbeCapture()
        let tester = ViewTester { BatchProbe(capture: capture) }
            .setSize(Size(width: 300, height: 100)).performLayout()
        let opacity = try #require(tester.findNodeByAccessibilityIdentifier("batch-opacity") as? OpacityViewNodeModifier)
        capture.builds = 0

        withTransaction(Transaction()) {
            capture.width.wrappedValue = 80
            withAnimation(.linear(duration: 1)) {
                #expect(capture.builds == 1)
                capture.opacity.wrappedValue = 0
            }
            capture.width.wrappedValue = 120
        }
        #expect(capture.builds == 3)
        enum ProbeError: Error { case expected }
        do {
            try withTransaction(Transaction()) {
                capture.opacity.wrappedValue = 0.75
                throw ProbeError.expected
            }
        } catch ProbeError.expected {}
        #expect(opacity.opacity == 0.75)
        #expect(StateUpdateBatch.current == nil)
        #expect(UITransactionContext.current == nil)
        tester.advanceFrame(deltaTime: 1)
        #expect(opacity.opacity == 0.75)
    }

    @Test
    func nestedPlainScopesCoalesceAndReduceRepeatedScreenRebuilds() {
        let capture = BatchProbeCapture()
        let tester = ViewTester { BatchProbe(capture: capture) }
            .setSize(Size(width: 300, height: 100)).performLayout()
        capture.builds = 0
        for index in 0..<50 {
            capture.width.wrappedValue = Float(80 + index)
            capture.opacity.wrappedValue = 0.5
            capture.width.wrappedValue = Float(100 + index)
        }
        let plainBuilds = capture.builds
        capture.builds = 0
        for index in 0..<50 {
            withTransaction(Transaction()) {
                capture.width.wrappedValue = Float(80 + index)
                withTransaction(Transaction()) { capture.opacity.wrappedValue = 0.5 }
                capture.width.wrappedValue = Float(100 + index)
            }
        }
        #expect(plainBuilds == 150)
        #expect(capture.builds == 50)
        print("PERFORMANCE 50 screen updates: plain \(plainBuilds) body builds; batched \(capture.builds)")
        tester.performLayout()
        #expect(tester.findNodeByAccessibilityIdentifier("batch-frame")?.frame.width == 149)
    }

    @Test
    func parentAndChildUpdatesRebuildChildOnceWithoutLosingIndependentState() {
        let capture = BatchProbeCapture()
        let root = BatchParent(capture: capture)
        let tester = ViewTester(rootView: root).setSize(Size(width: 300, height: 100)).performLayout()
        capture.builds = 0
        withTransaction(Transaction()) {
            capture.width.wrappedValue = 130
            root.version = 1
        }
        #expect(capture.builds == 1)
        #expect(capture.width.wrappedValue == 130)
        tester.performLayout()
        #expect(tester.findNodeByAccessibilityIdentifier("batch-frame")?.frame.width == 130)
    }
}

@MainActor
private final class BatchProbeCapture {
    var width: Binding<Float> = .constant(40)
    var opacity: Binding<Float> = .constant(1)
    var builds = 0
}

private struct BatchProbe: View {
    let capture: BatchProbeCapture
    @State private var width: Float = 40
    @State private var opacity: Float = 1

    var body: some View {
        capture.builds += 1
        capture.width = $width
        capture.opacity = $opacity
        return Color.red.frame(width: width, height: 40).accessibilityIdentifier("batch-frame")
            .opacity(opacity).accessibilityIdentifier("batch-opacity")
    }
}

private struct BatchParent: View {
    let capture: BatchProbeCapture
    @State var version = 0

    var body: some View {
        VStack {
            Text("Version \(version)")
            BatchProbe(capture: capture)
        }
    }
}
