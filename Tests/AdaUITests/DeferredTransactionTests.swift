import AdaAnimation
@testable import AdaPlatform
@testable import AdaUI
import AdaUtils
import Math
import Observation
import Testing

@MainActor
struct DeferredTransactionTests {
    init() async throws { try Application.prepareForTest() }

    @Test
    func geometryReaderPreservesObservedAnimationUntilLayout() async throws {
        let model = DeferredMetrics()
        let tester = ViewTester {
            GeometryReader { _ in
                Color.red.frame(width: 40, height: 40).opacity(model.opacity).accessibilityIdentifier("opacity")
            }
        }.setSize(Size(width: 300, height: 100)).performLayout()
        let node = try #require(tester.findNodeByAccessibilityIdentifier("opacity") as? OpacityViewNodeModifier)
        withAnimation(.linear(duration: 1)) { model.opacity = 0 }
        for _ in 0..<20 { await Task.yield() }
        tester.advanceFrame(deltaTime: 0.25)
        #expect(abs(node.opacity - 0.75) < 0.01)
        tester.advanceFrame(deltaTime: 0.75)
        #expect(node.opacity == 0)
    }

    @Test
    func geometryReaderImplicitAnimationTicksOncePerFrame() throws {
        let capture = DeferredBinding()
        let tester = ViewTester(rootView: DeferredStateView(capture: capture))
            .setSize(Size(width: 300, height: 100)).performLayout()
        let node = try #require(tester.findNodeByAccessibilityIdentifier("opacity") as? OpacityViewNodeModifier)
        withAnimation(.linear(duration: 2)) { capture.opacity.wrappedValue = 0 }
        tester.advanceFrame(deltaTime: 0.25)
        #expect(abs(node.opacity - 0.75) < 0.01)
        tester.advanceFrame(deltaTime: 0.25)
        #expect(abs(node.opacity - 0.5) < 0.01)
        tester.advanceFrame(deltaTime: 0.5)
        #expect(node.opacity == 0)
    }

    @Test(arguments: [false, true])
    func observedLayoutPreservesTransactionForPlacementAndMeasurement(measurement: Bool) async throws {
        let model = DeferredMetrics()
        let tester = ViewTester {
            ObservedMetricLayout(model: model, measurement: measurement) {
                Color.red.accessibilityIdentifier("layout-child")
            }.accessibilityIdentifier("layout")
        }.setSize(Size(width: 300, height: 100)).performLayout()
        let node = try #require(tester.findNodeByAccessibilityIdentifier(measurement ? "layout" : "layout-child"))
        withAnimation(.linear(duration: 1)) { model.extent = 140 }
        for _ in 0..<20 { await Task.yield() }
        tester.advanceFrame(deltaTime: 0)
        tester.advanceFrame(deltaTime: 0.5)
        let halfway = measurement ? node.frame.width : node.frame.minX
        #expect(abs(halfway - 90) < 0.01)
        tester.advanceFrame(deltaTime: 0.5)
        let end = measurement ? node.frame.width : node.frame.minX
        #expect(abs(end - 140) < 0.01)
    }

    @Test
    func geometryReaderPlainUpdateDoesNotReusePreviousAnimation() async throws {
        let model = DeferredMetrics()
        let tester = ViewTester {
            GeometryReader { _ in
                Color.red.frame(width: 40, height: 40).opacity(model.opacity).accessibilityIdentifier("opacity")
            }
        }.setSize(Size(width: 300, height: 100)).performLayout()
        let node = try #require(tester.findNodeByAccessibilityIdentifier("opacity") as? OpacityViewNodeModifier)
        withAnimation(.linear(duration: 1)) { model.opacity = 0 }
        for _ in 0..<20 { await Task.yield() }
        tester.advanceFrame(deltaTime: 0.5)
        model.opacity = 1
        for _ in 0..<20 { await Task.yield() }
        tester.advanceFrame(deltaTime: 0)
        #expect(node.opacity == 1)
        tester.advanceFrame(deltaTime: 1)
        #expect(node.opacity == 1)
    }

    @Test
    func deferredSiblingsKeepIndependentAnimationDurations() async throws {
        let left = DeferredMetrics()
        let right = DeferredMetrics()
        let tester = ViewTester {
            HStack {
                GeometryReader { _ in
                    Color.red.frame(width: 40, height: 40).opacity(left.opacity).accessibilityIdentifier("left")
                }
                GeometryReader { _ in
                    Color.blue.frame(width: 40, height: 40).opacity(right.opacity).accessibilityIdentifier("right")
                }
            }
        }.setSize(Size(width: 300, height: 100)).performLayout()
        let leftNode = try #require(tester.findNodeByAccessibilityIdentifier("left") as? OpacityViewNodeModifier)
        let rightNode = try #require(tester.findNodeByAccessibilityIdentifier("right") as? OpacityViewNodeModifier)
        withAnimation(.linear(duration: 0.5)) { left.opacity = 0 }
        withAnimation(.linear(duration: 2)) { right.opacity = 0 }
        for _ in 0..<20 { await Task.yield() }
        tester.advanceFrame(deltaTime: 0.25)
        #expect(abs(leftNode.opacity - 0.5) < 0.01)
        #expect(abs(rightNode.opacity - 0.875) < 0.01)
        tester.advanceFrame(deltaTime: 1.75)
        #expect(leftNode.opacity == 0)
        #expect(rightNode.opacity == 0)
    }

    @Test
    func observedLayoutHonorsAncestorAnimationSuppression() async throws {
        let model = DeferredMetrics()
        let tester = ViewTester {
            ObservedMetricLayout(model: model, measurement: false) {
                Color.red.accessibilityIdentifier("child")
            }.transaction { $0.disablesAnimations = true }
        }.setSize(Size(width: 300, height: 100)).performLayout()
        let node = try #require(tester.findNodeByAccessibilityIdentifier("child"))
        withAnimation(.linear(duration: 1)) { model.extent = 140 }
        for _ in 0..<20 { await Task.yield() }
        tester.advanceFrame(deltaTime: 0)
        #expect(node.frame.minX == 140)
        tester.advanceFrame(deltaTime: 0.5)
        #expect(node.frame.minX == 140)
    }
}

@MainActor @Observable
private final class DeferredMetrics {
    var opacity: Float = 1
    var extent: Float = 40
}

@MainActor
private final class DeferredBinding {
    var opacity: Binding<Float> = .constant(1)
}

private struct DeferredStateView: View {
    let capture: DeferredBinding
    @State private var opacity: Float = 1
    var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = capture.opacity = $opacity
        GeometryReader { _ in
            Color.red.frame(width: 40, height: 40).opacity(opacity).accessibilityIdentifier("opacity")
        }.animation(.linear(duration: 1), value: opacity)
    }
}

private struct ObservedMetricLayout: Layout {
    typealias AnimatableData = EmptyAnimatableData
    let model: DeferredMetrics
    let measurement: Bool

    func sizeThatFits(_ proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> Size {
        measurement ? Size(width: model.extent, height: 60) : proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: Rect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        for subview in subviews {
            subview.place(
                at: Point(measurement ? 0 : model.extent, 0),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: measurement ? bounds.width : 20, height: 20)
            )
        }
    }
}
