//
//  LazyVStackTests.swift
//  AdaEngine
//

import Testing
@testable import AdaPlatform
@testable import AdaUI
@testable import AdaUtils
import AdaInput
import Math

private struct LazyVStackEnvironmentCounterKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    fileprivate var lazyVStackEnvironmentCounter: Int {
        get { self[LazyVStackEnvironmentCounterKey.self] }
        set { self[LazyVStackEnvironmentCounterKey.self] = newValue }
    }
}

@MainActor
struct LazyVStackTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func lazyVStackBuildsOnlyVisibleRows() {
        final class BuildCounter {
            var count = 0
        }

        struct LargeList: View {
            let counter: BuildCounter
            let items = Array(0..<10_000)

            var body: some View {
                ScrollView(.vertical) {
                    LazyVStack(items, id: \.self, estimatedRowHeight: 24, overscan: 4) { item in
                        row(item)
                    }
                }
                .frame(width: 120, height: 120)
            }

            private func row(_ item: Int) -> some View {
                counter.count += 1
                return EmptyView()
                    .frame(width: 100, height: 24)
                    .accessibilityIdentifier("row-\(item)")
            }
        }

        let counter = BuildCounter()
        _ = ViewTester {
            LargeList(counter: counter)
        }

        #expect(counter.count < 100)
    }

    @Test
    func lazyVStackReusesRowsWhoseStableIDsRepresentTheirContent() {
        final class BuildCounter {
            var count = 0
        }

        final class ListState {
            var items = [0, 1, 2]
        }

        struct StableList: View {
            let state: ListState
            let counter: BuildCounter

            var body: some View {
                ScrollView(.vertical) {
                    LazyVStack(
                        state.items,
                        id: \.self,
                        estimatedRowHeight: 24,
                        overscan: 2,
                        reuseRowsWithStableIDs: true
                    ) { item in
                        counter.count += 1
                        return Text("Row \(item)")
                            .frame(width: 100, height: 24)
                    }
                }
                .frame(width: 120, height: 120)
            }
        }

        let state = ListState()
        let counter = BuildCounter()
        let tester = ViewTester {
            StableList(state: state, counter: counter)
        }
        .setSize(Size(width: 120, height: 120))
        .performLayout()
        let initialBuildCount = counter.count

        tester.invalidateContent().performLayout()
        #expect(counter.count == initialBuildCount)

        state.items[1] = 10
        tester.invalidateContent().performLayout()
        #expect(counter.count == initialBuildCount + 1)
    }

    @Test
    func lazyVStackUpdatesVisibleRowsWhenScrolled() throws {
        struct LargeList: View {
            let items = Array(0..<1_000)

            var body: some View {
                ScrollView(.vertical) {
                    LazyVStack(items, id: \.self, estimatedRowHeight: 32, overscan: 2) { item in
                        EmptyView()
                            .frame(width: 100, height: 32)
                            .accessibilityIdentifier("row-\(item)")
                    }
                }
                .frame(width: 120, height: 160)
                .accessibilityIdentifier("scroll")
            }
        }

        let tester = ViewTester {
            LargeList()
        }
        .setSize(Size(width: 120, height: 160))
        .performLayout()

        #expect(tester.findNodeByAccessibilityIdentifier("row-0") != nil)
        #expect(tester.findNodeByAccessibilityIdentifier("row-200") == nil)

        let scrollNode = try #require(firstScrollView(in: tester.containerView.viewTree.rootNode))
        scrollNode.scrollToViewNodeIfFoundIt(200, anchor: .top)

        #expect(tester.findNodeByAccessibilityIdentifier("row-200") != nil)
    }

    @Test
    func lazyVStackMeasuredHeightsUpdateContentHeight() {
        struct VariableHeightList: View {
            let items = Array(0..<3)

            var body: some View {
                ScrollView(.vertical) {
                    LazyVStack(items, id: \.self, spacing: 5, estimatedRowHeight: 20, overscan: 2) { item in
                        EmptyView()
                            .frame(width: 100, height: item == 1 ? 80 : 20)
                            .accessibilityIdentifier("row-\(item)")
                    }
                }
                .frame(width: 120, height: 80)
                .accessibilityIdentifier("scroll")
            }
        }

        let tester = ViewTester {
            VariableHeightList()
        }
        .setSize(Size(width: 120, height: 80))
        .performLayout()
        .performLayout()

        let row2 = tester.findNodeById(2)

        #expect(row2?.frame.origin.y == 110)
    }

    @Test
    func lazyVStackRepositionsFollowingRowsWhenVisibleRowGrowsUnderSameID() {
        let state = LazyVStackDynamicHeightState()
        state.expandedItem = nil
        state.expandedHeight = 40

        let tester = ViewTester {
            DynamicLazyVStackHeightList(state: state, spacing: 5, viewportHeight: 220)
        }
        .setSize(Size(width: 120, height: 220))
        .performLayout()
        .performLayout()

        #expect(tester.findNodeById(2)?.frame.origin.y == 90)

        state.expandedItem = 1
        state.expandedHeight = 120
        tester.invalidateContent().performLayout()

        #expect(tester.findNodeById(2)?.frame.origin.y == 170)
    }

    @Test
    func scrollToOffscreenLazyRowUsesEstimatedFrameAndBottomAnchor() throws {
        struct LargeList: View {
            let items = Array(0..<500)

            var body: some View {
                ScrollView(.vertical) {
                    LazyVStack(items, id: \.self, spacing: 0, estimatedRowHeight: 40, overscan: 2) { item in
                        EmptyView()
                            .frame(width: 100, height: 40)
                            .accessibilityIdentifier("row-\(item)")
                    }
                }
                .frame(width: 120, height: 160)
                .accessibilityIdentifier("scroll")
            }
        }

        let tester = ViewTester {
            LargeList()
        }
        .setSize(Size(width: 120, height: 160))
        .performLayout()

        let scrollNode = try #require(firstScrollView(in: tester.containerView.viewTree.rootNode))
        scrollNode.scrollToViewNodeIfFoundIt(300, anchor: .bottom)

        #expect(scrollNode.contentOffset.y == 11_880)
        #expect(tester.findNodeByAccessibilityIdentifier("row-300") != nil)
    }

    @Test
    func scrollToVisibleLazyRowBottomUsesUpdatedHeightAfterSameIDGrowth() throws {
        let state = LazyVStackDynamicHeightState()
        state.expandedItem = nil
        state.expandedHeight = 40

        let tester = ViewTester {
            DynamicLazyVStackHeightList(state: state, spacing: 0, viewportHeight: 100)
        }
        .setSize(Size(width: 120, height: 100))
        .performLayout()
        .performLayout()

        var scrollNode = try #require(firstScrollView(in: tester.containerView.viewTree.rootNode))
        scrollNode.scrollToViewNodeIfFoundIt(2, anchor: .bottom)
        #expect(scrollNode.contentOffset.y == 20)

        state.expandedItem = 2
        state.expandedHeight = 180
        tester.invalidateContent()

        scrollNode = try #require(firstScrollView(in: tester.containerView.viewTree.rootNode))
        scrollNode.scrollToViewNodeIfFoundIt(2, anchor: .bottom)

        #expect(scrollNode.contentOffset.y == 160)
    }

    @Test
    func lazyVStackChatLikeMarkdownRowKeepsMeasuredHeight() {
        let longMessage = """
        Что сделал:
        - Проанализировал текущий сайт: Swift Package + Ignite generator.
        - `Content/blog/*.md` с frontmatter.
        - `Assets/` со статикой: styles/images/fonts/js/CNAME.
        - Принял архитектурное решение: **Vite + TypeScript как build-платформа**.
        - Static SSG без SPA runtime: генерация реальных HTML-файлов для GitHub Pages.
        """

        let tester = ViewTester {
            ScrollView(.vertical) {
                LazyVStack([0, 1], id: \.self, alignment: .leading, spacing: 24, estimatedRowHeight: 80, overscan: 2) { item in
                    if item == 0 {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("SLOPPY")
                                .font(.system(size: 13))

                            Color.clear
                                .frame(height: 1)

                            Text(markdown: longMessage)
                                .font(.system(size: 17))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("assistant-message-text")
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("assistant-row")
                    } else {
                        Color.red
                            .frame(width: 100, height: 24)
                            .accessibilityIdentifier("next-row")
                    }
                }
            }
            .frame(width: 360, height: 180)
        }
        .setSize(Size(width: 360, height: 180))
        .performLayout()
        .performLayout()

        let assistantRow = tester.findNodeByAccessibilityIdentifier("assistant-row")
        let textNode = tester.findNodeByAccessibilityIdentifier("assistant-message-text")
        let nextRow = tester.findNodeByAccessibilityIdentifier("next-row")
        let assistantMaxY = assistantRow?.absoluteFrame().maxY ?? 0
        let nextMinY = nextRow?.absoluteFrame().minY ?? 0

        #expect((assistantRow?.frame.height ?? 0) > 150)
        #expect((textNode?.frame.height ?? 0) > 110)
        #expect(nextMinY >= assistantMaxY + 24)
    }

    @Test
    func lazyVStackPropagatesEnvironmentToVisibleRowsOnce() throws {
        let counter = LazyVStackEnvironmentUpdateCounter()

        let tester = ViewTester {
            ScrollView(.vertical) {
                LazyVStack(Array(0..<100), id: \.self, estimatedRowHeight: 24, overscan: 2) { item in
                    LazyVStackEnvironmentCountingRow(id: item, counter: counter)
                }
            }
            .frame(width: 120, height: 120)
        }
        .setSize(Size(width: 120, height: 120))
        .performLayout()

        let lazyNode = try #require(firstLazyVStackNode(in: tester.containerView.viewTree.rootNode))
        let visibleRows = lazyVStackEnvironmentCountingRows(in: lazyNode)
        #expect(!visibleRows.isEmpty)

        counter.reset()
        var environment = lazyNode.environment
        environment.lazyVStackEnvironmentCounter = 1
        lazyNode.updateEnvironment(environment)

        for row in visibleRows {
            #expect(counter.updateCounts[row.rowID] == 1)
        }

        counter.reset()
        lazyNode.updateEnvironment(lazyNode.environment)
        #expect(counter.updateCounts.isEmpty)
    }
}

@MainActor
private func firstScrollView(in node: ViewNode) -> ScrollViewNode? {
    if let scrollView = node as? ScrollViewNode {
        return scrollView
    }

    if let root = node as? ViewRootNode {
        return firstScrollView(in: root.contentNode)
    }

    if let modifier = node as? ViewModifierNode {
        return firstScrollView(in: modifier.contentNode)
    }

    if let container = node as? ViewContainerNode {
        for child in container.nodes {
            if let scrollView = firstScrollView(in: child) {
                return scrollView
            }
        }
    }

    return nil
}

@MainActor
private final class LazyVStackEnvironmentUpdateCounter {
    var updateCounts: [Int: Int] = [:]

    func record(rowID: Int) {
        updateCounts[rowID, default: 0] += 1
    }

    func reset() {
        updateCounts.removeAll()
    }
}

@MainActor
private final class LazyVStackDynamicHeightState {
    var expandedItem: Int?
    var expandedHeight: Float = 40
}

private struct DynamicLazyVStackHeightList: View {
    let state: LazyVStackDynamicHeightState
    let spacing: Float
    let viewportHeight: Float

    private let items = Array(0..<3)

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(items, id: \.self, alignment: .leading, spacing: spacing, estimatedRowHeight: 40, overscan: 3) { item in
                EmptyView()
                    .frame(width: 100, height: rowHeight(for: item))
                    .accessibilityIdentifier("row-\(item)")
            }
        }
        .frame(width: 120, height: viewportHeight)
        .accessibilityIdentifier("scroll")
    }

    private func rowHeight(for item: Int) -> Float {
        state.expandedItem == item ? state.expandedHeight : 40
    }
}

private struct LazyVStackEnvironmentCountingRow: View, ViewNodeBuilder {
    typealias Body = Never

    let id: Int
    let counter: LazyVStackEnvironmentUpdateCounter

    var body: Never { fatalError() }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let node = LazyVStackEnvironmentCountingRowNode(
            content: self,
            rowID: id,
            counter: counter
        )
        node.updateEnvironment(context.environment)
        return node
    }
}

private final class LazyVStackEnvironmentCountingRowNode: ViewNode {
    let rowID: Int
    let counter: LazyVStackEnvironmentUpdateCounter

    init<Content: View>(
        content: Content,
        rowID: Int,
        counter: LazyVStackEnvironmentUpdateCounter
    ) {
        self.rowID = rowID
        self.counter = counter
        super.init(content: content)
    }

    override func updateEnvironment(_ parentEnvironment: EnvironmentValues) {
        let previousVersion = environment.version
        super.updateEnvironment(parentEnvironment)
        if environment.version != previousVersion {
            counter.record(rowID: rowID)
        }
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        Size(width: proposal.width ?? 100, height: 24)
    }
}

@MainActor
private func firstLazyVStackNode(in node: ViewNode) -> ViewNode? {
    if String(describing: type(of: node)).hasPrefix("LazyVStackNode") {
        return node
    }

    if let root = node as? ViewRootNode {
        return firstLazyVStackNode(in: root.contentNode)
    }

    if let modifier = node as? ViewModifierNode {
        return firstLazyVStackNode(in: modifier.contentNode)
    }

    if let container = node as? ViewContainerNode {
        for child in container.nodes {
            if let lazyNode = firstLazyVStackNode(in: child) {
                return lazyNode
            }
        }
    }

    return nil
}

@MainActor
private func lazyVStackEnvironmentCountingRows(in node: ViewNode) -> [LazyVStackEnvironmentCountingRowNode] {
    var result: [LazyVStackEnvironmentCountingRowNode] = []

    if let row = node as? LazyVStackEnvironmentCountingRowNode {
        result.append(row)
    }

    if let root = node as? ViewRootNode {
        result += lazyVStackEnvironmentCountingRows(in: root.contentNode)
    } else if let modifier = node as? ViewModifierNode {
        result += lazyVStackEnvironmentCountingRows(in: modifier.contentNode)
    } else if let container = node as? ViewContainerNode {
        for child in container.nodes {
            result += lazyVStackEnvironmentCountingRows(in: child)
        }
    }

    return result
}
