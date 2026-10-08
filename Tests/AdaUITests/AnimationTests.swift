//
//  AnimationTests.swift
//
//
//  Created by Codex on 04.04.2026.
//

import Testing
import AdaAnimation
@testable import AdaPlatform
@testable import AdaUI
import AdaUtils
import Math

@MainActor
struct AnimationTests {

    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func scaleEffectDrawsAroundAnchorWithoutShiftingCenter() throws {
        let recorder = TransformRecordingStore()

        let tester = ViewTester {
            HStack {
                Button(action: {}) {
                    TransformRecordingCanvas(store: recorder)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(TransformRecordingButtonStyle())
                .scaleEffect(Vector2(1.1, 1.1))
                .accessibilityIdentifier("scaled-button")
            }
        }
        .setSize(Size(width: 200, height: 100))
        .performLayout()

        let scaledCenter = try renderRecordedCanvasCenter(in: tester, store: recorder)

        let unscaledRecorder = TransformRecordingStore()
        let unscaledTester = ViewTester {
            HStack {
                Button(action: {}) {
                    TransformRecordingCanvas(store: unscaledRecorder)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(TransformRecordingButtonStyle())
                .scaleEffect(Vector2.one)
                .accessibilityIdentifier("unscaled-button")
            }
        }
        .setSize(Size(width: 200, height: 100))
        .performLayout()

        let unscaledCenter = try renderRecordedCanvasCenter(in: unscaledTester, store: unscaledRecorder)

        #expect(abs(scaledCenter.x - unscaledCenter.x) < 0.01)
        #expect(abs(scaledCenter.y - unscaledCenter.y) < 0.01)
    }

    @Test
    func opacityAnimationProgressesAndCompletes() {
        let state = BindingBox(false)
        let tester = ViewTester(rootView: AnimatedOpacityView(isDimmed: state.binding))
            .setSize(Size(width: 200, height: 200))
            .performLayout()

        guard let node = tester.findNodeByAccessibilityIdentifier("opacity") as? OpacityViewNodeModifier else {
            Issue.record("Failed to locate opacity node.")
            return
        }

        #expect(abs(node.opacity - 1) < 0.001)

        state.value = true
        tester.invalidateContent()

        #expect(abs(node.opacity - 1) < 0.001)

        tester.advanceFrame(deltaTime: 0.5)
        #expect(abs(node.opacity - 0.625) < 0.01)

        tester.advanceFrame(deltaTime: 0.5)
        #expect(abs(node.opacity - 0.25) < 0.001)
    }

    @Test
    func bindingAnimationProgressesAndCompletes() {
        let capture = CapturedBoolBindings()
        let tester = ViewTester(rootView: BindingAnimatedOpacityStateView(capture: capture))
            .setSize(Size(width: 200, height: 200))
            .performLayout()

        guard let node = tester.findNodeByAccessibilityIdentifier("binding-opacity") as? OpacityViewNodeModifier else {
            Issue.record("Failed to locate binding opacity node.")
            return
        }

        #expect(abs(node.opacity - 1) < 0.001)

        capture.animated.wrappedValue = true

        #expect(abs(node.opacity - 1) < 0.001)

        tester.advanceFrame(deltaTime: 0.5)
        #expect(abs(node.opacity - 0.625) < 0.01)

        tester.advanceFrame(deltaTime: 0.5)
        #expect(abs(node.opacity - 0.25) < 0.001)
    }

    @Test
    func withAnimationProgressesAndCompletes() {
        let capture = CapturedBoolBindings()
        let tester = ViewTester(rootView: BindingAnimatedOpacityStateView(capture: capture))
            .setSize(Size(width: 200, height: 200))
            .performLayout()

        guard let node = tester.findNodeByAccessibilityIdentifier("binding-opacity") as? OpacityViewNodeModifier else {
            Issue.record("Failed to locate binding opacity node.")
            return
        }

        #expect(abs(node.opacity - 1) < 0.001)

        withAnimation(Animation.linear(duration: 1)) {
            capture.plain.wrappedValue = true
        }

        #expect(abs(node.opacity - 1) < 0.001)

        tester.advanceFrame(deltaTime: 0.5)
        #expect(abs(node.opacity - 0.625) < 0.01)

        tester.advanceFrame(deltaTime: 0.5)
        #expect(abs(node.opacity - 0.25) < 0.001)
    }

    @Test
    func nilWithAnimationSnapsWithoutAnimation() {
        let capture = CapturedBoolBindings()
        let tester = ViewTester(rootView: BindingAnimatedOpacityStateView(capture: capture))
            .setSize(Size(width: 200, height: 200))
            .performLayout()

        guard let node = tester.findNodeByAccessibilityIdentifier("binding-opacity") as? OpacityViewNodeModifier else {
            Issue.record("Failed to locate binding opacity node.")
            return
        }

        withAnimation(nil) {
            capture.plain.wrappedValue = true
        }

        #expect(abs(node.opacity - 0.25) < 0.001)

        tester.advanceFrame(deltaTime: 0.5)
        #expect(abs(node.opacity - 0.25) < 0.001)
    }

    @Test
    func nestedNilWithAnimationRestoresOuterAnimation() {
        let capture = CapturedBoolBindings()
        let tester = ViewTester(rootView: BindingAnimatedOpacityStateView(capture: capture))
            .setSize(Size(width: 200, height: 200))
            .performLayout()

        guard let node = tester.findNodeByAccessibilityIdentifier("binding-opacity") as? OpacityViewNodeModifier else {
            Issue.record("Failed to locate binding opacity node.")
            return
        }

        withAnimation(Animation.linear(duration: 1)) {
            withAnimation(nil) {
                capture.plain.wrappedValue = true
            }

            capture.plain.wrappedValue = false
        }

        #expect(abs(node.opacity - 0.25) < 0.001)

        tester.advanceFrame(deltaTime: 0.5)
        #expect(abs(node.opacity - 0.625) < 0.01)

        tester.advanceFrame(deltaTime: 0.5)
        #expect(abs(node.opacity - 1) < 0.001)
    }

    @Test
    func keyframeAnimatorAppliesEvaluatedValuesToViewNode() {
        let clip = KeyframeClip(name: "fade", initialValues: NodeOpacityKeyframeValue(opacity: 1), duration: 1) {
            KeyframeTrack(\.opacity) {
                LinearKeyframe(Float(1), duration: 1)
                LinearKeyframe(Float(0.25), duration: 0)
            }
        }
        let tester = ViewTester(
            rootView: Color.red
                .frame(width: 40, height: 40)
                .keyframeAnimator(clip)
        )
        .setSize(Size(width: 200, height: 200))
        .performLayout()

        guard let node = tester.containerView.viewTree.rootNode.contentNode as? KeyframeAnimatorViewNode<NodeOpacityKeyframeValue> else {
            Issue.record("Failed to locate keyframe animator node.")
            return
        }

        #expect(abs(node.animatedOpacity - 1) < 0.001)

        tester.advanceFrame(deltaTime: 0.5)
        #expect(abs(node.animatedOpacity - 0.625) < 0.01)

        tester.advanceFrame(deltaTime: 0.5)
        #expect(abs(node.animatedOpacity - 0.25) < 0.001)
    }

    @Test
    func plainBindingUpdateAfterBindingAnimationDoesNotAnimate() {
        let capture = CapturedBoolBindings()
        let tester = ViewTester(rootView: BindingAnimatedOpacityStateView(capture: capture))
            .setSize(Size(width: 200, height: 200))
            .performLayout()

        guard let node = tester.findNodeByAccessibilityIdentifier("binding-opacity") as? OpacityViewNodeModifier else {
            Issue.record("Failed to locate binding opacity node.")
            return
        }

        capture.animated.wrappedValue = true
        tester.advanceFrame(deltaTime: 1)
        #expect(abs(node.opacity - 0.25) < 0.001)

        capture.plain.wrappedValue = false
        #expect(abs(node.opacity - 1) < 0.001)
    }

    @Test
    func scaleAndRotationAnimateThroughTransformPresentationValue() {
        let scaleState = BindingBox(false)
        let scaleTester = ViewTester(rootView: AnimatedScaleView(isScaled: scaleState.binding))
            .setSize(Size(width: 200, height: 200))
            .performLayout()

        guard let scaleNode = scaleTester.findNodeByAccessibilityIdentifier("scale") as? TransformEffectViewNode<Vector2> else {
            Issue.record("Failed to locate scale transform node.")
            return
        }

        scaleState.value = true
        scaleTester.invalidateContent()
        scaleTester.advanceFrame(deltaTime: 0.5)
        #expect(abs(scaleNode.value.x - 1.5) < 0.01)
        #expect(abs(scaleNode.value.y - 1.5) < 0.01)

        let rotationState = BindingBox(false)
        let rotationTester = ViewTester(rootView: AnimatedRotationView(isRotated: rotationState.binding))
            .setSize(Size(width: 200, height: 200))
            .performLayout()

        guard let rotationNode = rotationTester.findNodeByAccessibilityIdentifier("rotation") as? TransformEffectViewNode<Float> else {
            Issue.record("Failed to locate rotation transform node.")
            return
        }

        rotationState.value = true
        rotationTester.invalidateContent()
        rotationTester.advanceFrame(deltaTime: 0.5)
        #expect(abs(rotationNode.value - Angle.degrees(45).radians) < 0.01)
    }

    @Test
    func animationRetargetsFromCurrentPresentationValue() {
        let state = BindingBox(false)
        let tester = ViewTester(rootView: AnimatedOffsetCard(isShifted: state.binding))
            .setSize(Size(width: 260, height: 120))
            .performLayout()

        guard let node = tester.findNodeByAccessibilityIdentifier("offset-card") else {
            Issue.record("Failed to locate animated offset node.")
            return
        }

        let initialX = node.absoluteFrame().origin.x

        state.value = true
        tester.invalidateContent()
        tester.advanceFrame(deltaTime: 0)
        tester.advanceFrame(deltaTime: 0.4)
        let halfwayX = tester.findNodeByAccessibilityIdentifier("offset-card")?.absoluteFrame().origin.x ?? node.absoluteFrame().origin.x
        #expect(abs((halfwayX - initialX) - 40) < 0.01)

        state.value = false
        tester.invalidateContent()
        tester.advanceFrame(deltaTime: 0)
        tester.advanceFrame(deltaTime: 0.2)
        let retargetedX = tester.findNodeByAccessibilityIdentifier("offset-card")?.absoluteFrame().origin.x ?? node.absoluteFrame().origin.x
        #expect(retargetedX < halfwayX)
        #expect(retargetedX > initialX)

        tester.advanceFrame(deltaTime: 0.8)
        let finalX = tester.findNodeByAccessibilityIdentifier("offset-card")?.absoluteFrame().origin.x ?? node.absoluteFrame().origin.x
        #expect(abs(finalX - initialX) < 0.001)
    }

    @Test
    func frameSizeAnimationRelayoutsSubtree() {
        let state = BindingBox(false)
        let tester = ViewTester(rootView: AnimatedFrameContainer(isExpanded: state.binding))
            .setSize(Size(width: 240, height: 120))
            .performLayout()

        guard
            let frameNode = tester.findNodeByAccessibilityIdentifier("frame-container"),
            let contentNode = tester.findNodeByAccessibilityIdentifier("frame-content")
        else {
            Issue.record("Failed to locate frame animation nodes.")
            return
        }

        state.value = true
        tester.invalidateContent()
        tester.advanceFrame(deltaTime: 0)
        tester.advanceFrame(deltaTime: 0.5)

        #expect(abs(frameNode.absoluteFrame().width - 80) < 0.01)
        #expect(abs(contentNode.absoluteFrame().width - 80) < 0.01)

        tester.advanceFrame(deltaTime: 0.5)
        #expect(abs(frameNode.absoluteFrame().width - 120) < 0.01)
        #expect(abs(contentNode.absoluteFrame().width - 120) < 0.01)
    }

    @Test
    func nilAnimationSnapsImmediately() {
        let state = BindingBox(false)
        let tester = ViewTester(rootView: NilAnimationOpacityView(isDimmed: state.binding))
            .setSize(Size(width: 200, height: 200))
            .performLayout()

        guard let node = tester.findNodeByAccessibilityIdentifier("nil-opacity") as? OpacityViewNodeModifier else {
            Issue.record("Failed to locate nil animation opacity node.")
            return
        }

        #expect(abs(node.opacity - 1) < 0.001)

        state.value = true
        tester.invalidateContent()
        tester.advanceFrame(deltaTime: 0)

        #expect(abs(node.opacity - 0.25) < 0.001)

        tester.advanceFrame(deltaTime: 0.5)
        #expect(abs(node.opacity - 0.25) < 0.001)
    }

    @Test
    func roundedRectangleShapeAnimatesCornerRadius() {
        let state = BindingBox(false)
        let tester = ViewTester(rootView: AnimatedRoundedRectangleShapeView(isRounded: state.binding))
            .setSize(Size(width: 200, height: 120))
            .performLayout()

        state.value = true
        tester.invalidateContent()

        guard let startPath = firstPath(in: tester) else {
            Issue.record("Expected rounded rectangle path before animation advances.")
            return
        }

        #expect(abs((firstMoveX(in: startPath) ?? -1) - 0) < 0.01)

        tester.advanceFrame(deltaTime: 0.5)

        guard let halfPath = firstPath(in: tester) else {
            Issue.record("Expected rounded rectangle path during animation.")
            return
        }

        #expect(abs((firstMoveX(in: halfPath) ?? -1) - 10) < 0.01)

        tester.advanceFrame(deltaTime: 0.5)

        guard let finalPath = firstPath(in: tester) else {
            Issue.record("Expected rounded rectangle path after animation.")
            return
        }

        #expect(abs((firstMoveX(in: finalPath) ?? -1) - 20) < 0.01)
    }

    @Test
    func customShapeAnimatableDataAnimates() {
        let state = BindingBox(false)
        let tester = ViewTester(rootView: AnimatedCustomShapeView(isInset: state.binding))
            .setSize(Size(width: 200, height: 120))
            .performLayout()

        state.value = true
        tester.invalidateContent()
        tester.advanceFrame(deltaTime: 0)
        tester.advanceFrame(deltaTime: 0.5)

        guard let path = firstPath(in: tester) else {
            Issue.record("Expected custom shape path during animation.")
            return
        }

        #expect(abs((firstMoveX(in: path) ?? -1) - 8) < 0.01)
    }

    @Test
    func shapePathUpdatesDuringFrameAnimation() {
        let state = BindingBox(false)
        let tester = ViewTester(rootView: AnimatedShapeFrameView(isExpanded: state.binding))
            .setSize(Size(width: 260, height: 120))
            .performLayout()

        state.value = true
        tester.invalidateContent()
        tester.advanceFrame(deltaTime: 0)
        tester.advanceFrame(deltaTime: 0.5)

        guard let path = firstPath(in: tester) else {
            Issue.record("Expected shape path during frame animation.")
            return
        }

        #expect(abs((maxLineX(in: path) ?? -1) - 140) < 0.01)
    }

    @Test
    func hstackReflowAnimatesRetainedSiblingPlacement() {
        let state = BindingBox(false)
        let tester = ViewTester(rootView: AnimatedReflowView(isExpanded: state.binding))
            .setSize(Size(width: 260, height: 120))
            .performLayout()

        guard let siblingNode = tester.findNodeByAccessibilityIdentifier("reflow-sibling") else {
            Issue.record("Failed to locate reflow sibling.")
            return
        }

        let initialX = siblingNode.absoluteFrame().origin.x

        state.value = true
        tester.invalidateContent()
        tester.advanceFrame(deltaTime: 0)

        #expect(abs(siblingNode.absoluteFrame().origin.x - initialX) < 0.01)

        tester.advanceFrame(deltaTime: 0.5)
        #expect(abs((siblingNode.absoluteFrame().origin.x - initialX) - 40) < 0.01)

        tester.advanceFrame(deltaTime: 0.5)
        #expect(abs((siblingNode.absoluteFrame().origin.x - initialX) - 80) < 0.01)
    }

    @Test
    func hitTestingUsesPresentationGeometryDuringAnimation() {
        let state = BindingBox(false)
        let tester = ViewTester(rootView: AnimatedButtonOffsetView(isShifted: state.binding))
            .setSize(Size(width: 260, height: 120))
            .performLayout()

        guard let buttonNode = tester.findNodeByAccessibilityIdentifier("moving-button") else {
            Issue.record("Failed to locate moving button.")
            return
        }

        let originalCenter = Point(x: buttonNode.absoluteFrame().midX, y: buttonNode.absoluteFrame().midY)

        state.value = true
        tester.invalidateContent()
        tester.advanceFrame(deltaTime: 0)
        tester.advanceFrame(deltaTime: 0.5)

        let presentedFrame = buttonNode.absoluteFrame()
        let presentedCenter = Point(x: presentedFrame.midX, y: presentedFrame.midY)

        #expect(tester.click(at: originalCenter) == nil)
        #expect(tester.click(at: presentedCenter)?.id == buttonNode.id)
    }

    @Test
    func hoverFrameInStackUsesAnimatedPresentationGeometryAfterExpansion() {
        let state = BindingBox(false)
        var hoverEvents: [Bool] = []
        let tester = ViewTester(
            rootView: AnimatedHoverIslandView(
                isExpanded: state.binding,
                onHover: { hoverEvents.append($0) }
            )
        )
        .setSize(Size(width: 640, height: 124))
        .performLayout()

        guard let initialHoverNode = tester.findNodeByAccessibilityIdentifier("hover-island") else {
            Issue.record("Failed to locate hover island.")
            return
        }
        #expect(abs(initialHoverNode.absoluteFrame().width - 196) < 0.01)

        state.value = true
        tester.invalidateContent()
        tester.performLayout()
        tester.advanceFrame(deltaTime: 0)
        tester.advanceFrame(deltaTime: 0.5)

        guard let hoverNode = tester.findNodeByAccessibilityIdentifier("hover-island") else {
            Issue.record("Failed to locate updated hover island.")
            return
        }

        #expect(hoverNode.id == initialHoverNode.id)
        #expect(hoverNode.environment.animationController != nil)

        var frame = hoverNode.absoluteFrame()
        #expect(abs(frame.width - 318) < 0.01)

        tester.advanceFrame(deltaTime: 0.5)
        frame = hoverNode.absoluteFrame()
        #expect(abs(frame.midX - 320) < 0.01)
        #expect(abs(frame.width - 440) < 0.01)

        tester.sendMouseEvent(at: Point(frame.midX, frame.midY), button: .none, phase: .changed)
        tester.sendMouseEvent(at: Point(40, frame.midY), button: .none, phase: .changed)

        #expect(hoverEvents == [true, false])
    }

    @Test
    func disableAnimationSnapsImmediately() {
        let state = BindingBox(false)
        let tester = ViewTester(rootView: DisabledAnimationOffsetView(isShifted: state.binding))
            .setSize(Size(width: 260, height: 120))
            .performLayout()

        guard let node = tester.findNodeByAccessibilityIdentifier("disabled-offset") else {
            Issue.record("Failed to locate disabled animation node.")
            return
        }

        let initialX = node.absoluteFrame().origin.x

        state.value = true
        tester.invalidateContent()
        tester.advanceFrame(deltaTime: 0)

        let updatedNode = tester.findNodeByAccessibilityIdentifier("disabled-offset") ?? node
        #expect(abs((updatedNode.absoluteFrame().origin.x - initialX) - 100) < 0.001)

        tester.advanceFrame(deltaTime: 0.5)
        let finalNode = tester.findNodeByAccessibilityIdentifier("disabled-offset") ?? updatedNode
        #expect(abs((finalNode.absoluteFrame().origin.x - initialX) - 100) < 0.001)
    }

    @Test
    func animationRequestsAnotherRedrawWhilePlaying() {
        let state = BindingBox(false)
        let tester = ViewTester(rootView: AnimatedOpacityView(isDimmed: state.binding))
            .setSize(Size(width: 200, height: 200))
            .performLayout()

        _ = tester.containerView.consumeNeedsDisplay()

        state.value = true
        tester.invalidateContent()
        _ = tester.containerView.consumeNeedsDisplay()

        tester.advanceFrame(deltaTime: 0.1)

        #expect(tester.containerView.consumeNeedsDisplay())
    }

    @Test
    func insertionAndRemovalStillSnapWithoutTransitions() {
        let state = BindingBox(false)
        let tester = ViewTester(rootView: ConditionalInsertionView(isPresented: state.binding))
            .setSize(Size(width: 240, height: 120))
            .performLayout()

        #expect(tester.findNodeByAccessibilityIdentifier("inserted-card") == nil)

        state.value = true
        tester.invalidateContent()
        tester.advanceFrame(deltaTime: 0)

        guard let insertedNode = tester.findNodeByAccessibilityIdentifier("inserted-card") else {
            Issue.record("Inserted node should appear immediately.")
            return
        }

        #expect(abs(insertedNode.absoluteFrame().origin.x) < 0.001)

        state.value = false
        tester.invalidateContent()
        #expect(tester.findNodeByAccessibilityIdentifier("inserted-card") == nil)
    }

    private func firstPath<Content: View>(in tester: ViewTester<Content>) -> Path? {
        let context = UIGraphicsContext()
        tester.containerView.draw(
            in: Rect(origin: .zero, size: tester.containerView.frame.size),
            with: context
        )

        for command in context.getDrawCommands() {
            if case let .drawPath(path, _, _) = command {
                return path
            }
        }

        return nil
    }

    private func firstMoveX(in path: Path) -> Float? {
        var result: Float?
        path.forEach { element in
            guard result == nil else { return }
            if case let .move(to: point) = element {
                result = point.x
            }
        }
        return result
    }

    private func maxLineX(in path: Path) -> Float? {
        var result: Float?
        path.forEach { element in
            let x: Float?
            switch element {
            case let .move(to: point), let .line(to: point):
                x = point.x
            case let .quadCurve(to: point, control: control):
                x = max(point.x, control.x)
            case let .curve(to: point, control1: control1, control2: control2):
                x = max(point.x, max(control1.x, control2.x))
            case .closeSubpath:
                x = nil
            }

            if let x {
                result = max(result ?? x, x)
            }
        }
        return result
    }
}

@MainActor
private final class TransformRecordingStore: @unchecked Sendable {
    var transforms: [Transform3D] = []
}

private struct TransformRecordingCanvas: View {
    let store: TransformRecordingStore

    var body: some View {
        Canvas { context, _ in
            store.transforms.append(context.transform)
        }
    }
}

private struct TransformRecordingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

@MainActor
private func renderRecordedCanvasCenter<Content: View>(in tester: ViewTester<Content>, store: TransformRecordingStore) throws -> Point {
    tester.containerView.viewTree.rootNode.draw(with: UIGraphicsContext())
    let transform = try #require(store.transforms.last)
    return transformedPoint(Point(x: 20, y: -20), by: transform)
}

private func transformedPoint(_ point: Point, by transform: Transform3D) -> Point {
    let vector = transform * Vector4(point.x, point.y, 0, 1)
    return Point(x: vector.x, y: vector.y)
}

private final class BindingBox<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }

    var binding: Binding<Value> {
        Binding(
            get: { self.value },
            set: { self.value = $0 }
        )
    }
}

@MainActor
private final class CapturedBoolBindings {
    var animated: Binding<Bool>!
    var plain: Binding<Bool>!
}

private struct BindingAnimatedOpacityStateView: View {
    let capture: CapturedBoolBindings
    @State private var isDimmed = false

    var body: some View {
        let _ = capture.animated = $isDimmed.animation(Animation.linear(duration: 1))
        let _ = capture.plain = $isDimmed

        Color.red
            .frame(width: 40, height: 40)
            .opacity(isDimmed ? 0.25 : 1)
            .accessibilityIdentifier("binding-opacity")
    }
}

private struct AnimatedOpacityView: View {
    let isDimmed: Binding<Bool>

    var body: some View {
        Color.red
            .frame(width: 40, height: 40)
            .opacity(isDimmed.wrappedValue ? 0.25 : 1)
            .accessibilityIdentifier("opacity")
            .animation(Animation.linear(duration: 1), value: isDimmed.wrappedValue)
    }
}

private struct NodeOpacityKeyframeValue: UIKeyframeAnimatable {
    var opacity: Float

    @MainActor
    func apply(to node: KeyframeAnimatorNodeProxy) {
        node.opacity = opacity
    }
}

private struct AnimatedScaleView: View {
    let isScaled: Binding<Bool>

    var body: some View {
        Color.blue
            .frame(width: 40, height: 40)
            .scaleEffect(isScaled.wrappedValue ? Vector2(2, 2) : Vector2.one)
            .accessibilityIdentifier("scale")
            .animation(Animation.linear(duration: 1), value: isScaled.wrappedValue)
    }
}

private struct AnimatedRotationView: View {
    let isRotated: Binding<Bool>

    var body: some View {
        Color.green
            .frame(width: 40, height: 40)
            .rotationEffect(isRotated.wrappedValue ? Angle.degrees(90) : .zero)
            .accessibilityIdentifier("rotation")
            .animation(Animation.linear(duration: 1), value: isRotated.wrappedValue)
    }
}

private struct AnimatedOffsetCard: View {
    let isShifted: Binding<Bool>

    var body: some View {
        Color.orange
            .frame(width: 40, height: 40)
            .accessibilityIdentifier("offset-card")
            .offset(x: isShifted.wrappedValue ? 100 : 0)
            .animation(Animation.linear(duration: 1), value: isShifted.wrappedValue)
    }
}

private struct AnimatedFrameContainer: View {
    let isExpanded: Binding<Bool>

    var body: some View {
        Color.purple
            .accessibilityIdentifier("frame-content")
            .frame(width: isExpanded.wrappedValue ? 120 : 40, height: 40)
            .accessibilityIdentifier("frame-container")
            .animation(Animation.linear(duration: 1), value: isExpanded.wrappedValue)
    }
}

private struct NilAnimationOpacityView: View {
    let isDimmed: Binding<Bool>

    var body: some View {
        Color.red
            .frame(width: 40, height: 40)
            .opacity(isDimmed.wrappedValue ? 0.25 : 1)
            .accessibilityIdentifier("nil-opacity")
            .animation(nil, value: isDimmed.wrappedValue)
    }
}

private struct AnimatedRoundedRectangleShapeView: View {
    let isRounded: Binding<Bool>

    var body: some View {
        RoundedRectangleShape(cornerRadius: isRounded.wrappedValue ? 20 : 0)
            .fill(Color.red)
            .frame(width: 100, height: 50)
            .accessibilityIdentifier("rounded-shape")
            .animation(Animation.linear(duration: 1), value: isRounded.wrappedValue)
    }
}

private struct AnimatableInsetRectangleShape: Shape {
    var inset: Float

    var animatableData: Float {
        get { inset }
        set { inset = newValue }
    }

    func path(in rect: Rect) -> Path {
        Path { path in
            path.addRect(
                Rect(
                    x: inset,
                    y: inset,
                    width: max(0, rect.width - inset * 2),
                    height: max(0, rect.height - inset * 2)
                )
            )
        }
    }
}

private struct AnimatedCustomShapeView: View {
    let isInset: Binding<Bool>

    var body: some View {
        AnimatableInsetRectangleShape(inset: isInset.wrappedValue ? 16 : 0)
            .fill(Color.blue)
            .frame(width: 80, height: 40)
            .accessibilityIdentifier("custom-shape")
            .animation(Animation.linear(duration: 1), value: isInset.wrappedValue)
    }
}

private struct AnimatedShapeFrameView: View {
    let isExpanded: Binding<Bool>

    var body: some View {
        RectangleShape()
            .fill(Color.green)
            .frame(width: isExpanded.wrappedValue ? 180 : 100, height: 40)
            .accessibilityIdentifier("shape-frame")
            .animation(Animation.linear(duration: 1), value: isExpanded.wrappedValue)
    }
}

private struct AnimatedReflowView: View {
    let isExpanded: Binding<Bool>

    var body: some View {
        HStack(spacing: 0) {
            Color.red
                .frame(width: isExpanded.wrappedValue ? 120 : 40, height: 40)
                .accessibilityIdentifier("reflow-driver")

            Color.blue
                .frame(width: 40, height: 40)
                .accessibilityIdentifier("reflow-sibling")
        }
        .frame(width: 260, height: 40, alignment: .leading)
        .animation(Animation.linear(duration: 1), value: isExpanded.wrappedValue)
    }
}

private struct AnimatedButtonOffsetView: View {
    let isShifted: Binding<Bool>

    var body: some View {
        Button(action: { }) {
            Color.accentColor
                .frame(width: 40, height: 40)
        }
        .accessibilityIdentifier("moving-button")
        .offset(x: isShifted.wrappedValue ? 100 : 0)
            .animation(Animation.linear(duration: 1), value: isShifted.wrappedValue)
    }
}

private struct AnimatedHoverIslandView: View {
    let isExpanded: Binding<Bool>
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            Color.black
                .frame(width: isExpanded.wrappedValue ? 440 : 196, height: isExpanded.wrappedValue ? 104 : 36)
                .onHover(perform: onHover)
                .onTap { }
                .accessibilityIdentifier("hover-island")
            Spacer()
        }
        .frame(width: 640, height: 124, alignment: .top)
        .animation(Animation.linear(duration: 1), value: isExpanded.wrappedValue)
    }
}

private struct DisabledAnimationOffsetView: View {
    let isShifted: Binding<Bool>

    var body: some View {
        Color.red
            .frame(width: 40, height: 40)
            .accessibilityIdentifier("disabled-offset")
            .offset(x: isShifted.wrappedValue ? 100 : 0)
            .animation(Animation.linear(duration: 1), value: isShifted.wrappedValue)
            .disableAnimation()
    }
}

private struct ConditionalInsertionView: View {
    let isPresented: Binding<Bool>

    var body: some View {
        HStack(spacing: 0) {
            if isPresented.wrappedValue {
                Color.yellow
                    .frame(width: 40, height: 40)
                    .accessibilityIdentifier("inserted-card")
            }

            Color.gray
                .frame(width: 40, height: 40)
                .accessibilityIdentifier("persistent-card")
        }
        .frame(width: 240, height: 40, alignment: .leading)
        .animation(Animation.linear(duration: 1), value: isPresented.wrappedValue)
    }
}
