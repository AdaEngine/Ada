//
//  AdaUILayoutOptimizationTests.swift
//  AdaEngine
//

import Math
import Observation
import Synchronization
import Testing
@testable import AdaPlatform
@testable import AdaUI

@MainActor
struct AdaUILayoutOptimizationTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func scrollViewProxyRegistryDoesNotTriggerObservationInvalidation() {
        let proxy = _ScrollViewProxy()
        let didInvalidate = Mutex(false)

        withObservationTracking {
            _ = proxy.subscribedScrollViewNodes.count
        } onChange: {
            didInvalidate.withLock { value in
                value = true
            }
        }

        proxy.subscribedScrollViewNodes = []

        #expect(!didInvalidate.withLock { $0 })
    }

    @Test
    func repeatedContainerLayoutWithSameSizeSkipsCleanSubtreeLayout() {
        let counter = LayoutOptimizationCounter()
        let tester = ViewTester {
            CountingFixedView(counter: counter, size: Size(width: 120, height: 80))
        }
        .setSize(Size(width: 300, height: 200))
        .performLayout()

        counter.layoutPasses = 0
        UILayoutDebugCounters.isEnabled = true
        UILayoutDebugCounters.reset()
        tester.performLayout()
        let snapshot = UILayoutDebugCounters.snapshot
        UILayoutDebugCounters.isEnabled = false

        #expect(counter.layoutPasses == 0)
        #expect(snapshot.layoutPasses == 0)
    }

    @Test
    func geometryReaderDoesNotRebuildContentWhenGeometryIsUnchanged() {
        let counter = LayoutOptimizationCounter()
        let tester = ViewTester {
            GeometryReader { proxy in
                CountingFixedView(counter: counter, size: counter.recordGeometryBuild(size: proxy.size))
            }
        }
        .setSize(Size(width: 320, height: 180))
        .performLayout()

        let buildsAfterInitialLayout = counter.geometryBuilds
        tester.performLayout()

        #expect(counter.geometryBuilds == buildsAfterInitialLayout)
    }

    @Test
    func geometryReaderUsesParentProposalForOwnSize() {
        let counter = LayoutOptimizationCounter()
        let tester = ViewTester {
            GeometryReader { proxy in
                CountingFixedView(
                    counter: counter,
                    size: counter.recordGeometryBuild(size: proxy.size)
                )
                .frame(width: 960, height: 600)
            }
        }
        .setSize(Size(width: 320, height: 180))
        .performLayout()

        let rootContent = tester.containerView.viewTree.rootNode.contentNode

        #expect(rootContent.frame.size == Size(width: 320, height: 180))
        #expect(counter.geometryBuilds >= 1)
    }

    @Test
    func geometryReaderRebuildsContentWhenGeometryChanges() {
        let counter = LayoutOptimizationCounter()
        let tester = ViewTester {
            GeometryReader { proxy in
                CountingFixedView(counter: counter, size: counter.recordGeometryBuild(size: proxy.size))
            }
        }
        .setSize(Size(width: 320, height: 180))
        .performLayout()

        let buildsAfterInitialLayout = counter.geometryBuilds
        tester
            .setSize(Size(width: 360, height: 180))
            .performLayout()

        #expect(counter.geometryBuilds > buildsAfterInitialLayout)
    }

    @Test
    func geometryReaderRebuildsContentWhenObservedStateChanges() async {
        let model = GeometryReaderObservableModel()
        let counter = LayoutOptimizationCounter()
        let tester = ViewTester {
            GeometryReader { _ in
                if model.showsPopup {
                    CountingFixedView(counter: counter, size: Size(width: 120, height: 30))
                        .accessibilityIdentifier("geometry-popup")
                }
            }
        }
        .setSize(Size(width: 320, height: 180))
        .performLayout()

        #expect(tester.findNodeByAccessibilityIdentifier("geometry-popup") == nil)

        model.showsPopup = true
        for _ in 0..<3 {
            await Task.yield()
        }
        tester.performLayout()

        #expect(tester.findNodeByAccessibilityIdentifier("geometry-popup") != nil)
    }

    @Test
    func geometryReaderReportsOwnFrameInCoordinateSpaces() {
        let recorder = GeometryFrameRecorder()
        let namedSpace = NamedViewCoordinateSpace.named("geometry-container")

        _ = ViewTester {
            ZStack(anchor: .topLeading) {
                GeometryReader { proxy in
                    GeometryFrameProbe(
                        recorder: recorder,
                        localFrame: proxy.frame(in: .local),
                        globalFrame: proxy.frame(in: .global),
                        namedFrame: proxy.frame(in: namedSpace),
                        size: proxy.size
                    )
                }
                .frame(width: 80, height: 40)
                .offset(x: 25, y: 15)
            }
            .frame(width: 200, height: 100, alignment: .topLeading)
            .coordinateSpace(namedSpace)
        }
        .setSize(Size(width: 300, height: 200))
        .performLayout()

        #expect(recorder.size == Size(width: 80, height: 40))
        #expect(recorder.localFrame == Rect(x: 0, y: 0, width: 80, height: 40))
        #expect(recorder.namedFrame == Rect(x: 25, y: 15, width: 80, height: 40))
        #expect(recorder.globalFrame == Rect(x: 75, y: 65, width: 80, height: 40))
    }

    @Test
    func stateChangeStillUpdatesLayoutOnNextLayoutPass() {
        let counter = LayoutOptimizationCounter()
        let tester = ViewTester {
            StatefulLayoutOptimizationView(counter: counter)
        }
        .setSize(Size(width: 300, height: 200))
        .performLayout()

        let initialFrame = tester.findNodeByAccessibilityIdentifier("state-child")?.frame
        let toggleFrame = tester.findNodeByAccessibilityIdentifier("toggle")?.absoluteFrame() ?? .zero
        let toggleCenter = Point(toggleFrame.midX, toggleFrame.midY)
        tester.sendMouseEvent(at: toggleCenter, button: .left, phase: .began)
        tester.sendMouseEvent(at: toggleCenter, button: .left, phase: .ended)
        tester.performLayout()

        let updatedFrame = tester.findNodeByAccessibilityIdentifier("state-child")?.frame
        #expect(initialFrame?.height == 30)
        #expect(updatedFrame?.height == 80)
    }

    @Test
    func stackLayoutReusesMeasurementsInsidePlacementPass() {
        let counter = LayoutOptimizationCounter()
        let tester = ViewTester {
            VStack(spacing: 4) {
                CountingFixedView(counter: counter, size: Size(width: 40, height: 10))
                CountingFixedView(counter: counter, size: Size(width: 50, height: 20))
                CountingFixedView(counter: counter, size: Size(width: 60, height: 30))
            }
        }
        .setSize(Size(width: 300, height: 200))
        .performLayout()

        counter.sizeThatFitsCalls = 0
        tester
            .setSize(Size(width: 320, height: 200))
            .performLayout()

        #expect(counter.sizeThatFitsCalls <= 12)
    }

    @Test
    func leafStateChangeWithStableSizeDoesNotRelayoutLargeScreen() {
        let staticCounter = LayoutOptimizationCounter()
        let leafCounter = LayoutOptimizationCounter()
        let recorder = LeafStateRecorder()
        let tester = ViewTester {
            VStack(spacing: 0) {
                CountingFixedView(counter: staticCounter, size: Size(width: 280, height: 120))
                    .accessibilityIdentifier("large-static-panel")
                StableSizeStateLeaf(recorder: recorder, counter: leafCounter)
            }
            .frame(width: 320, height: 240)
        }
        .setSize(Size(width: 320, height: 240))
        .performLayout()

        staticCounter.layoutPasses = 0
        leafCounter.layoutPasses = 0
        UILayoutDebugCounters.isEnabled = true
        UILayoutDebugCounters.reset()

        recorder.binding?.wrappedValue += 1
        tester.performLayout()

        let snapshot = UILayoutDebugCounters.snapshot
        UILayoutDebugCounters.isEnabled = false

        #expect(recorder.renderedValues.last == 1)
        #expect(staticCounter.layoutPasses == 0)
        #expect(leafCounter.layoutPasses >= 1)
        #expect(snapshot.rebuilds == 1)
    }

    @Test
    func stableSizeStateChangeSchedulesLayoutIfNeededForRebuiltSubtree() {
        let counter = LayoutOptimizationCounter()
        let recorder = LeafStateRecorder()
        let tester = ViewTester {
            StableSizeSwappingStateLeaf(recorder: recorder, counter: counter)
                .frame(width: 120, height: 60)
        }
        .setSize(Size(width: 160, height: 100))
        .performLayout()

        recorder.binding?.wrappedValue = 1
        tester.containerView.layoutIfNeeded()

        let updatedNode = tester.findNodeByAccessibilityIdentifier("stable-swap-b")
        #expect(updatedNode?.frame.size == Size(width: 80, height: 30))
    }

    @Test
    func observableLeafChangeWithStableSizeDoesNotRelayoutLargeScreen() async {
        let counter = LayoutOptimizationCounter()
        let model = StableSizeObservableModel()
        let recorder = StableSizeObservableRecorder()
        let tester = ViewTester {
            VStack(spacing: 0) {
                CountingFixedView(counter: counter, size: Size(width: 280, height: 120))
                    .accessibilityIdentifier("large-static-panel")
                StableSizeObservableLeaf(model: model, recorder: recorder, counter: counter)
            }
            .frame(width: 320, height: 240)
        }
        .setSize(Size(width: 320, height: 240))
        .performLayout()

        model.value = 1
        for _ in 0..<3 {
            await Task.yield()
        }

        counter.layoutPasses = 0
        tester.performLayout()

        #expect(recorder.renderedValues.last == 1)
        #expect(counter.layoutPasses == 0)
    }

    @Test
    func nestedObservableChangeDoesNotInvalidateParentSiblings() async throws {
        let model = NestedObservablePanelModel()
        let topCounter = LayoutOptimizationCounter()
        let workspaceCounter = LayoutOptimizationCounter()
        let window = UIWindow(frame: Rect(x: 0, y: 0, width: 320, height: 240))
        let containerView = UIContainerView(
            rootView: NestedObservableInvalidationRoot(
                model: model,
                topCounter: topCounter,
                workspaceCounter: workspaceCounter
            )
        )

        containerView.frame = Rect(x: 0, y: 0, width: 320, height: 240)
        window.addSubview(containerView)
        window.layoutIfNeeded()
        _ = window.consumeDirtyRect()

        topCounter.updatePasses = 0
        workspaceCounter.updatePasses = 0

        model.showPanel = false
        for _ in 0..<3 {
            await Task.yield()
        }

        let dirtyRect = try #require(window.consumeDirtyRect())
        containerView.layoutIfNeeded()

        #expect(topCounter.updatePasses == 0)
        #expect(workspaceCounter.updatePasses > 0)
        #expect(dirtyRect == Rect(x: 0, y: 40, width: 320, height: 200))
        #expect(containerView.viewTree.rootNode.findNodyByAccessibilityIdentifier("left-panel") == nil)
        #expect(containerView.viewTree.rootNode.findNodyByAccessibilityIdentifier("main-panel")?.frame.size == Size(width: 320, height: 200))
    }

    @Test
    func observedLayoutPriorityChangeRelayoutsParentStack() async throws {
        let model = ObservableLayoutPriorityModel()
        let tester = ViewTester {
            ObservableLayoutPriorityView(model: model)
        }
        .setSize(Size(width: 300, height: 80))
        .performLayout()

        let initialPrimaryWidth = try #require(
            tester.findNodeByAccessibilityIdentifier("priority-primary")?.frame.width
        )
        let initialSecondaryWidth = try #require(
            tester.findNodeByAccessibilityIdentifier("priority-secondary")?.frame.width
        )

        model.primaryIsHighPriority = false
        for _ in 0..<3 {
            await Task.yield()
        }
        tester.performLayout()

        let updatedPrimaryWidth = try #require(
            tester.findNodeByAccessibilityIdentifier("priority-primary")?.frame.width
        )
        let updatedSecondaryWidth = try #require(
            tester.findNodeByAccessibilityIdentifier("priority-secondary")?.frame.width
        )

        #expect(initialPrimaryWidth > initialSecondaryWidth)
        #expect(updatedPrimaryWidth < updatedSecondaryWidth)
    }

    @Test
    func observedKeyedReorderRelayoutsEqualSizeStack() async throws {
        let model = ObservableKeyedOrderModel()
        let tester = ViewTester {
            ObservableKeyedOrderView(model: model)
        }
        .setSize(Size(width: 200, height: 40))
        .performLayout()

        let initialFirstX = try #require(
            tester.findNodeByAccessibilityIdentifier("ordered-1")?.absoluteFrame().minX
        )
        let initialSecondX = try #require(
            tester.findNodeByAccessibilityIdentifier("ordered-2")?.absoluteFrame().minX
        )

        model.items.reverse()
        for _ in 0..<3 {
            await Task.yield()
        }
        tester.performLayout()

        let updatedFirstX = try #require(
            tester.findNodeByAccessibilityIdentifier("ordered-1")?.absoluteFrame().minX
        )
        let updatedSecondX = try #require(
            tester.findNodeByAccessibilityIdentifier("ordered-2")?.absoluteFrame().minX
        )

        #expect(initialFirstX < initialSecondX)
        #expect(updatedFirstX > updatedSecondX)
    }

    @Test
    func observedFrameRuleChangeRelayoutsInsideFixedContainer() async throws {
        let model = ObservableFrameRuleModel()
        let tester = ViewTester {
            ObservableFrameRuleView(model: model)
        }
        .setSize(Size(width: 300, height: 40))
        .performLayout()

        let initialWidth = try #require(
            tester.findNodeByAccessibilityIdentifier("dynamic-frame")?.frame.width
        )

        model.isExpanded = true
        for _ in 0..<3 {
            await Task.yield()
        }
        tester.performLayout()

        let updatedWidth = try #require(
            tester.findNodeByAccessibilityIdentifier("dynamic-frame")?.frame.width
        )

        #expect(initialWidth == 80)
        #expect(updatedWidth == 120)
    }

    @Test
    func observedFrameAlignmentChangeRelayoutsUnchangedModifierFrame() async throws {
        let model = ObservableFrameAlignmentModel()
        let tester = ViewTester {
            ObservableFrameAlignmentView(model: model)
        }
        .setSize(Size(width: 200, height: 40))
        .performLayout()

        let initialX = try #require(
            tester.findNodeByAccessibilityIdentifier("alignment-child")?.absoluteFrame().minX
        )

        model.isTrailing = true
        for _ in 0..<3 {
            await Task.yield()
        }
        tester.performLayout()

        let updatedX = try #require(
            tester.findNodeByAccessibilityIdentifier("alignment-child")?.absoluteFrame().minX
        )

        #expect(initialX == 0)
        #expect(updatedX == 160)
    }
}

@MainActor
private final class LayoutOptimizationCounter {
    var geometryBuilds = 0
    var layoutPasses = 0
    var sizeThatFitsCalls = 0
    var updatePasses = 0

    func recordGeometryBuild(size: Size) -> Size {
        geometryBuilds += 1
        return size
    }
}

@MainActor
private final class GeometryFrameRecorder {
    var localFrame = Rect.zero
    var globalFrame = Rect.zero
    var namedFrame = Rect.zero
    var size = Size.zero
}

@MainActor
private final class LeafStateRecorder {
    var binding: Binding<Int>?
    var renderedValues: [Int] = []

    func record(value: Int, binding: Binding<Int>) {
        self.binding = binding
        self.renderedValues.append(value)
    }
}

@Observable
@MainActor
private final class StableSizeObservableModel {
    var value = 0
}

@Observable
@MainActor
private final class GeometryReaderObservableModel {
    var showsPopup = false
}

@Observable
@MainActor
private final class NestedObservablePanelModel {
    var showPanel = true
}

@Observable
@MainActor
private final class ObservableLayoutPriorityModel {
    var primaryIsHighPriority = true
}

@Observable
@MainActor
private final class ObservableKeyedOrderModel {
    var items = [1, 2]
}

@Observable
@MainActor
private final class ObservableFrameRuleModel {
    var isExpanded = false
}

@Observable
@MainActor
private final class ObservableFrameAlignmentModel {
    var isTrailing = false
}

@MainActor
private final class StableSizeObservableRecorder {
    var renderedValues: [Int] = []

    func record(value: Int) {
        renderedValues.append(value)
    }
}

private struct GeometryFrameProbe: View, ViewNodeBuilder {
    let recorder: GeometryFrameRecorder
    let localFrame: Rect
    let globalFrame: Rect
    let namedFrame: Rect
    let size: Size

    var body: Never {
        fatalError()
    }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        recorder.localFrame = localFrame
        recorder.globalFrame = globalFrame
        recorder.namedFrame = namedFrame
        recorder.size = size
        return GeometryFrameProbeNode(content: self)
    }
}

private final class GeometryFrameProbeNode: ViewNode {
    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }
}

private struct CountingFixedView: View, ViewNodeBuilder {
    let counter: LayoutOptimizationCounter
    let size: Size

    var body: Never {
        fatalError()
    }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        CountingFixedViewNode(content: self, counter: counter, size: size)
    }
}

private final class CountingFixedViewNode: ViewNode {
    private let counter: LayoutOptimizationCounter
    private var fixedSize: Size

    init(content: CountingFixedView, counter: LayoutOptimizationCounter, size: Size) {
        self.counter = counter
        self.fixedSize = size
        super.init(content: content)
    }

    override func update(from newNode: ViewNode) {
        if let other = newNode as? CountingFixedViewNode {
            self.fixedSize = other.fixedSize
        }
        counter.updatePasses += 1
        super.update(from: newNode)
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        counter.sizeThatFitsCalls += 1
        return fixedSize
    }

    override func performLayout() {
        counter.layoutPasses += 1
        super.performLayout()
    }
}

private struct StatefulLayoutOptimizationView: View {
    let counter: LayoutOptimizationCounter
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button("toggle") {
                expanded.toggle()
            }
            .frame(width: 100, height: 40)
            .accessibilityIdentifier("toggle")

            CountingFixedView(
                counter: counter,
                size: Size(width: 80, height: expanded ? 80 : 30)
            )
            .accessibilityIdentifier("state-child")
        }
    }
}

private struct StableSizeStateLeaf: View {
    let recorder: LeafStateRecorder
    let counter: LayoutOptimizationCounter

    @State private var value = 0

    var body: some View {
        let _ = recorder.record(value: value, binding: $value)
        CountingFixedView(counter: counter, size: Size(width: 80, height: 30))
            .accessibilityIdentifier("stable-state-leaf")
    }
}

private struct StableSizeSwappingStateLeaf: View {
    let recorder: LeafStateRecorder
    let counter: LayoutOptimizationCounter

    @State private var value = 0

    var body: some View {
        let _ = recorder.record(value: value, binding: $value)
        if value == 0 {
            CountingFixedView(counter: counter, size: Size(width: 80, height: 30))
                .accessibilityIdentifier("stable-swap-a")
        } else {
            CountingFixedView(counter: counter, size: Size(width: 80, height: 30))
                .accessibilityIdentifier("stable-swap-b")
        }
    }
}

private struct StableSizeObservableLeaf: View {
    let model: StableSizeObservableModel
    let recorder: StableSizeObservableRecorder
    let counter: LayoutOptimizationCounter

    var body: some View {
        let _ = recorder.record(value: model.value)
        VStack(spacing: 0) {
            CountingFixedView(counter: counter, size: Size(width: 80, height: 30))
                .accessibilityIdentifier("stable-observable-leaf")
        }
    }
}

private struct NestedObservableInvalidationRoot: View {
    let model: NestedObservablePanelModel
    let topCounter: LayoutOptimizationCounter
    let workspaceCounter: LayoutOptimizationCounter

    var body: some View {
        VStack(spacing: 0) {
            CountingFixedView(counter: topCounter, size: Size(width: 320, height: 40))
                .accessibilityIdentifier("unchanged-topbar")

            NestedObservableInvalidationWorkspace(model: model, counter: workspaceCounter)
                .frame(width: 320, height: 200)
                .accessibilityIdentifier("workspace")
        }
    }
}

private struct NestedObservableInvalidationWorkspace: View {
    let model: NestedObservablePanelModel
    let counter: LayoutOptimizationCounter

    var body: some View {
        HStack(spacing: 0) {
            if model.showPanel {
                CountingFixedView(counter: counter, size: Size(width: 80, height: 200))
                    .accessibilityIdentifier("left-panel")
            }

            CountingFixedView(counter: counter, size: Size(width: model.showPanel ? 240 : 320, height: 200))
                .accessibilityIdentifier("main-panel")
        }
    }
}

private struct ObservableLayoutPriorityView: View {
    let model: ObservableLayoutPriorityModel

    var body: some View {
        HStack(spacing: 0) {
            EmptyView()
                .frame(height: 20)
                .frame(maxWidth: .infinity)
                .layoutPriority(model.primaryIsHighPriority ? 1 : 0)
                .accessibilityIdentifier("priority-primary")
            EmptyView()
                .frame(height: 20)
                .frame(maxWidth: .infinity)
                .layoutPriority(model.primaryIsHighPriority ? 0 : 1)
                .accessibilityIdentifier("priority-secondary")
        }
    }
}

private struct ObservableKeyedOrderView: View {
    let model: ObservableKeyedOrderModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(model.items, id: \.self) { item in
                EmptyView()
                    .frame(width: item == 1 ? 80 : 120, height: 40)
                    .accessibilityIdentifier("ordered-\(item)")
            }
        }
    }
}

private struct ObservableFrameRuleView: View {
    let model: ObservableFrameRuleModel

    var body: some View {
        HStack(spacing: 0) {
            EmptyView()
                .frame(width: model.isExpanded ? 120 : 80, height: 40)
                .accessibilityIdentifier("dynamic-frame")
            Spacer()
        }
        .frame(width: 300, height: 40)
    }
}

private struct ObservableFrameAlignmentView: View {
    let model: ObservableFrameAlignmentModel

    var body: some View {
        EmptyView()
            .frame(width: 40, height: 40)
            .accessibilityIdentifier("alignment-child")
            .frame(
                width: 200,
                height: 40,
                alignment: model.isTrailing ? .trailing : .leading
            )
    }
}
