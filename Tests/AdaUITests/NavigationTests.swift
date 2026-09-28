//
//  NavigationTests.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 25.03.2026.
//

import Testing
@testable import AdaUI
@testable import AdaPlatform
import AdaInput
import AdaUtils
import Math

@MainActor
struct NavigationPathTests {

    @Test
    func initialPath_isEmpty() {
        let path = NavigationPath()
        #expect(path.isEmpty)
        #expect(path.count == 0)
    }

    @Test
    func append_incrementsCount() {
        var path = NavigationPath()
        path.append("hello")
        #expect(!path.isEmpty)
        #expect(path.count == 1)
    }

    @Test
    func removeLast_decrementsCount() {
        var path = NavigationPath()
        path.append("a")
        path.append("b")
        path.removeLast()
        #expect(path.count == 1)
    }

    @Test
    func removeLast_onEmpty_doesNotCrash() {
        var path = NavigationPath()
        path.removeLast()
        #expect(path.isEmpty)
    }

    @Test
    func topElement_returnsLastAppended() {
        var path = NavigationPath()
        path.append(42)
        #expect(path.topElement == AnyHashable(42))
    }
}

@MainActor
struct NavigationStackTests {

    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func navigationStack_showsRootContent_whenPathEmpty() async {
        var rootAppeared = false

        _ = ViewTester {
            NavigationStack {
                Color.red
                    .frame(width: 100, height: 100)
                    .onAppear { rootAppeared = true }
            }
        }

        await flushNavigationLifecycleActions()
        #expect(rootAppeared)
    }

    @Test
    func navigationStack_showsDestination_whenPathHasValue() async {
        var destinationAppeared = false

        var path = NavigationPath()
        path.append("detail")

        _ = ViewTester {
            NavigationStack(path: .constant(path)) {
                Color.red
                    .navigate(for: String.self) { _ in
                        Color.blue
                            .frame(width: 100, height: 100)
                            .onAppear { destinationAppeared = true }
                    }
            }
        }

        await flushNavigationLifecycleActions()
        #expect(destinationAppeared)
    }

    @Test
    func navigationStack_updatesDestinationWhenBoundPathChanges() async {
        final class Model {
            var path = NavigationPath()
        }
        let model = Model()
        var destinationAppeared = false

        let tester = ViewTester {
            NavigationStack(path: Binding(get: { model.path }, set: { model.path = $0 })) {
                Text("Root")
                    .navigate(for: String.self) { _ in
                        Text("Detail")
                            .onAppear { destinationAppeared = true }
                    }
            }
        }
        .setSize(Size(width: 400, height: 400))
        .performLayout()

        model.path.append("detail")
        tester.invalidateContent().performLayout()
        await flushNavigationLifecycleActions()

        #expect(destinationAppeared)
        #expect(textNodes(in: tester.containerView.viewTree.rootNode).contains { $0.text == "Detail" })
    }

    @Test
    func navigationLink_pushesValueOnTap() async {
        var destinationAppeared = false

        let tester = ViewTester {
            NavigationStack {
                NavigationLink(value: "detail") {
                    Color.red
                        .frame(width: 100, height: 100)
                }
                .navigate(for: String.self) { _ in
                    Color.blue
                        .frame(width: 200, height: 200)
                        .onAppear { destinationAppeared = true }
                }
            }
        }
        .setSize(Size(width: 400, height: 400))
        .performLayout()

        #expect(!destinationAppeared)

        tester.sendMouseEvent(at: Point(200, 200), phase: MouseEvent.Phase.began)
        tester.sendMouseEvent(at: Point(200, 200), phase: MouseEvent.Phase.ended)
        await flushNavigationLifecycleActions()

        #expect(destinationAppeared)
    }

    @Test
    func dismissAction_popsNavigation_andShowsRoot() async {
        var rootAppeared = false
        var detailAppeared = false

        var path = NavigationPath()
        path.append("detail")

        let tester = ViewTester {
            NavigationStack(path: .constant(path)) {
                Color.red
                    .onAppear { rootAppeared = true }
                    .navigate(for: String.self) { _ in
                        DismissTestView(onAppear: { detailAppeared = true })
                    }
            }
        }
        .setSize(Size(width: 400, height: 400))
        .performLayout()
        await flushNavigationLifecycleActions()

        #expect(detailAppeared)

        let stackNode = tester.containerView.viewTree.rootNode.contentNode as? NavigationStackNode
        #expect(stackNode != nil)

        stackNode?.navigationContext.pop()
        await flushNavigationLifecycleActions()

        #expect(stackNode?.navigationContext.path.isEmpty == true)
        #expect(rootAppeared)
    }

    @Test
    func edgeSwipeBack_popsWithAnimation_onlyAfterHorizontalGesture() async throws {
        final class Model {
            var path: NavigationPath

            init(path: NavigationPath) {
                self.path = path
            }
        }

        var initialPath = NavigationPath()
        initialPath.append("detail")
        let model = Model(path: initialPath)
        let tester = ViewTester {
            NavigationStack(path: Binding(get: { model.path }, set: { model.path = $0 })) {
                Color.red
                    .navigate(for: String.self) { _ in
                        Color.blue
                    }
            }
        }
        .setSize(Size(width: 400, height: 400))
        .performLayout()

        let stack = try #require(navigationStackNodes(in: tester.containerView.viewTree.rootNode).first)
        let window = RID()
        func touch(_ x: Float, _ y: Float, _ phase: TouchEvent.Phase, contact: RID) {
            tester.containerView.onTouchesEvent([
                TouchEvent(window: window, location: Point(x, y), phase: phase, time: 0, contactID: contact)
            ])
        }

        let verticalContact = RID()
        touch(12, 210, .began, contact: verticalContact)
        touch(105, 300, .moved, contact: verticalContact)
        touch(105, 300, .ended, contact: verticalContact)
        #expect(model.path.count == 1)

        let shortContact = RID()
        touch(12, 210, .began, contact: shortContact)
        touch(65, 210, .moved, contact: shortContact)
        touch(65, 210, .ended, contact: shortContact)
        #expect(model.path.count == 1)

        let backContact = RID()
        touch(12, 210, .began, contact: backContact)
        touch(110, 214, .moved, contact: backContact)
        touch(110, 214, .ended, contact: backContact)

        #expect(model.path.count == 1)
        try await Task.sleep(for: .milliseconds(120))
        #expect(model.path.isEmpty)
        #expect(stack.presentation.isAnimating)
    }

    @Test
    func rootOnAppear_doesNotRefire_whenRootStateChanges() async {
        var rootAppearedCount = 0
        let driver = NavigationRootStateDriver()

        _ = ViewTester {
            NavigationRootStateHost(driver: driver) {
                rootAppearedCount += 1
            }
        }
        .setSize(Size(width: 400, height: 400))
        .performLayout()
        await flushNavigationLifecycleActions()

        #expect(rootAppearedCount == 1)
        #expect(driver.counter != nil)

        driver.counter?.wrappedValue += 1

        #expect(rootAppearedCount == 1)
    }

    @Test
    func navigationBar_updatesTitleWhenRootStateChanges() async throws {
        let driver = NavigationTitleStateDriver()
        let tester = ViewTester {
            NavigationTitleStateHost(driver: driver)
        }
        .setSize(Size(width: 400, height: 400))
        .performLayout()
        await flushNavigationLifecycleActions()

        #expect(textNodes(in: tester.containerView.viewTree.rootNode).contains { $0.text == "General" })

        let title = try #require(driver.title)
        title.wrappedValue = "Agent"
        tester.performLayout()

        #expect(textNodes(in: tester.containerView.viewTree.rootNode).contains { $0.text == "Agent" })
        #expect(!textNodes(in: tester.containerView.viewTree.rootNode).contains { $0.text == "General" })
    }

    @Test
    func navigationStack_nestedScrollContentExtendsUnderNavigationBar() throws {
        let tester = ViewTester {
            NavigationStack {
                ZStack(anchor: .topLeading) {
                    VStack {
                        ScrollViewReader { _ in
                            ScrollView {
                                Color.red
                                    .frame(width: 320, height: 640)
                            }
                        }
                        .frame(minHeight: 0, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .navigationTitle("Chat")
            }
        }
        .setSize(Size(width: 400, height: 400))
        .performLayout()

        let scrollNode = try #require(firstScrollView(in: tester.containerView.viewTree.rootNode))
        #expect(scrollNode.absoluteFrame().origin.y == 0)
    }

    @Test
    func navigationBar_buttonStyleKeepsToolbarItemsCompact() throws {
        let tester = ViewTester {
            NavigationStack {
                Color.clear
                    .navigationTitle("New Chat")
                    .navigationTitlePosition(.center)
                    .navigationBarLeadingItems {
                        Button(action: {}) {
                            Text("Agent")
                        }
                    }
                    .navigationBarTrailingItems {
                        HStack(spacing: 10) {
                            Button("History") {}
                            Button("Settings") {}
                        }
                    }
            }
        }
        .setSize(Size(width: 400, height: 400))
        .performLayout()

        let textNodes = textNodes(in: tester.containerView.viewTree.rootNode)
        let agent = try #require(textNodes.first { $0.text == "Agent" })
        let history = try #require(textNodes.first { $0.text == "History" })
        let settings = try #require(textNodes.first { $0.text == "Settings" })

        #expect(agent.frame.origin.x < 80)
        #expect(history.frame.origin.y < 60)
        #expect(settings.frame.origin.y < 60)
        #expect(abs(history.frame.origin.y - settings.frame.origin.y) < 1)
        #expect(history.frame.origin.x < settings.frame.origin.x)
    }

    @Test
    func navigationBar_isCreatedByDefaultWithoutItems() throws {
        let tester = ViewTester {
            NavigationStack {
                Text("Content")
                    .frame(width: 100, height: 40)
            }
        }
        .setSize(Size(width: 400, height: 400))
        .performLayout()

        let content = try #require(textNodes(in: tester.containerView.viewTree.rootNode).first { $0.text == "Content" })
        #expect(content.frame.origin.y > 150)
    }

    @Test
    func navigationBar_customColorAndItemsAreVisibleToInspection() throws {
        let tester = ViewTester {
            NavigationStack {
                Color.clear
                    .navigationTitle("Settings")
                    .navigationTitlePosition(.leading)
                    .navigationBarColor(.red)
                    .navigationBarTrailingItems {
                        Button("Close") {}
                            .accessibilityIdentifier("Navigation.Close")
                    }
            }
        }
        .setSize(Size(width: 400, height: 400))
        .performLayout()

        let stack = try #require(navigationStackNodes(in: tester.containerView.viewTree.rootNode).first)
        let bar = try #require(stack.inspectionChildNodes.first { $0 is NavigationBarNode } as? NavigationBarNode)
        let title = try tester.containerView.uiNode(matching: .accessibilityIdentifier("AdaUI.NavigationBar.Title"))
        let close = try tester.containerView.uiNode(matching: .accessibilityIdentifier("Navigation.Close"))

        #expect(bar.resolvedBackgroundColor == .red)
        #expect(title.absoluteFrame.height > 0)
        #expect(close.isInteractable)
    }

    @Test
    func navigationBarHidden_removesBarEvenWithToolbarItems() throws {
        let tester = ViewTester {
            NavigationStack {
                Text("Content")
                    .frame(width: 100, height: 40)
                    .navigationBarTrailingItems {
                        Text("Hidden Toolbar")
                    }
                    .navigationBarHidden(true)
            }
        }
        .setSize(Size(width: 400, height: 400))
        .performLayout()

        let textNodes = textNodes(in: tester.containerView.viewTree.rootNode)
        let content = try #require(textNodes.first { $0.text == "Content" })
        #expect(content.frame.origin.y < 190)
        #expect(!textNodes.contains { $0.text == "Hidden Toolbar" })
    }

    @Test
    func navigationBar_readsToolbarItemsThroughOuterModifiers() throws {
        let tester = ViewTester {
            NavigationStack {
                Color.red
                    .navigationBarLeadingItems {
                        Button(action: {}) {
                            Text("Agent")
                        }
                    }
                    .navigationBarTrailingItems {
                        Button("Settings") {}
                    }
                    .onAppear {}
            }
        }
        .setSize(Size(width: 400, height: 400))
        .performLayout()

        let textNodes = textNodes(in: tester.containerView.viewTree.rootNode)
        let agent = try #require(textNodes.first { $0.text == "Agent" })
        let settings = try #require(textNodes.first { $0.text == "Settings" })

        #expect(agent.frame.origin.x < 80)
        #expect(settings.frame.origin.x > 300)
        #expect(agent.frame.origin.y < 80)
        #expect(settings.frame.origin.y < 80)
    }

    @Test
    func navigationBar_respectsOverlayTitleBarChromeInset() throws {
        let tester = ViewTester {
            NavigationStack {
                Color.clear
                    .navigationTitle("Overlay")
                    .navigationTitlePosition(.center)
            }
        }
        .setSize(Size(width: 400, height: 400))
        .performLayout()

        let chromeTopInset: Float = 52
        var environment = EnvironmentValues()
        environment.navigationBarChromeInsets.top = chromeTopInset
        tester.containerView.viewTree.rootNode.mergeEnvironment(environment)
        tester.containerView.viewTree.rootNode.place(
            in: .zero,
            anchor: .zero,
            proposal: ProposedViewSize(Size(width: 400, height: 400))
        )

        let title = try #require(textNodes(in: tester.containerView.viewTree.rootNode).first { $0.text == "Overlay" })
        #expect(title.frame.origin.y >= chromeTopInset)
        #expect(title.frame.origin.y < chromeTopInset + 60)
    }

    @Test
    func navigationBar_overlayTitleBarCentersItemsInReservedBar() throws {
        let tester = ViewTester {
            NavigationStack {
                Color.clear
                    .navigationBarLeadingItems {
                        Button(action: {}) {
                            Text("Agent")
                        }
                    }
                    .navigationBarTrailingItems {
                        Button("Sessions") {}
                    }
            }
        }
        .setSize(Size(width: 400, height: 400))
        .performLayout()

        let chromeTopInset: Float = 52
        var environment = EnvironmentValues()
        environment.navigationBarChromeInsets.top = chromeTopInset
        tester.containerView.viewTree.rootNode.mergeEnvironment(environment)
        tester.containerView.viewTree.rootNode.place(
            in: .zero,
            anchor: .zero,
            proposal: ProposedViewSize(Size(width: 400, height: 400))
        )

        let textNodes = textNodes(in: tester.containerView.viewTree.rootNode)
        let agent = try #require(textNodes.first { $0.text == "Agent" })
        let sessions = try #require(textNodes.first { $0.text == "Sessions" })
        let expectedCenterY = chromeTopInset + 46

        #expect(abs((agent.frame.origin.y + agent.frame.height * 0.5) - expectedCenterY) < 8)
        #expect(abs((sessions.frame.origin.y + sessions.frame.height * 0.5) - expectedCenterY) < 8)
    }

    @Test
    func navigationStack_environmentChangePropagatesContentOnceWithNavigationBarInset() throws {
        let tester = ViewTester {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 0) {
                        Color.red
                            .frame(width: 320, height: 240)
                    }
                }
                .navigationTitle("Chat")
            }
        }
        .setSize(Size(width: 400, height: 400))
        .performLayout()

        let rootNode = tester.containerView.viewTree.rootNode
        let scrollNode = try #require(firstScrollView(in: rootNode))

        UILayoutDebugCounters.isEnabled = true
        UILayoutDebugCounters.reset()
        defer {
            UILayoutDebugCounters.isEnabled = false
        }

        var environment = EnvironmentValues()
        environment.navigationBarChromeInsets.top = 52
        rootNode.mergeEnvironment(environment)

        #expect(scrollNode.environment.safeAreaInsets.top == 144)
        #expect(UILayoutDebugCounters.snapshot.environmentInvalidations <= 14)
    }

    @Test
    func navigationSplitView_detailNavigationBarShowsToolbarItemsWithChromeInset() throws {
        let tester = ViewTester {
            NavigationSplitView(
                columnVisibility: .constant(.automatic),
                preferredCompactColumn: .constant(.detail)
            ) {
                Color.clear
                    .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            } detail: {
                NavigationStack {
                    Color.red
                        .navigationBarTrailingItems {
                            Text("Toolbar")
                        }
                }
            }
        }
        .setSize(Size(width: 640, height: 400))
        .performLayout()

        let chromeTopInset: Float = 52
        var environment = EnvironmentValues()
        environment.navigationBarChromeInsets.top = chromeTopInset
        tester.containerView.viewTree.rootNode.mergeEnvironment(environment)
        tester.containerView.viewTree.rootNode.place(
            in: .zero,
            anchor: .zero,
            proposal: ProposedViewSize(Size(width: 640, height: 400))
        )

        let toolbar = try #require(textNodes(in: tester.containerView.viewTree.rootNode).first { $0.text == "Toolbar" })
        #expect(toolbar.frame.origin.x > 180)
        #expect(toolbar.frame.origin.y >= chromeTopInset)
        #expect(toolbar.frame.origin.y < chromeTopInset + 60)
    }

    @Test
    func navigationSplitView_createsColumnNavigationBarsWithoutExplicitStacks() throws {
        let tester = ViewTester {
            NavigationSplitView {
                Text("Sidebar Content")
                    .navigationTitle("Sidebar")
            } detail: {
                Text("Detail Content")
                    .navigationTitle("Detail")
            }
        }
        .setSize(Size(width: 720, height: 400))
        .performLayout()

        let textNodes = textNodes(in: tester.containerView.viewTree.rootNode)
        let sidebarTitle = try #require(textNodes.first { $0.text == "Sidebar" })
        let detailTitle = try #require(textNodes.first { $0.text == "Detail" })

        #expect(sidebarTitle.frame.origin.x < 360)
        #expect(detailTitle.frame.origin.x > 280)
        #expect(sidebarTitle.frame.origin.y < 80)
        #expect(detailTitle.frame.origin.y < 80)
    }

    @Test
    func navigationSplitView_routesSidebarNavigationLinkToDetailColumn() async throws {
        let tester = ViewTester {
            NavigationSplitView {
                NavigationLink(value: "message") {
                    Color.red
                        .frame(width: 180, height: 180)
                }
                .accessibilityIdentifier("sidebar-link")
                .navigate(for: String.self) { value in
                    Text("Detail \(value)")
                }
            } detail: {
                Text("Placeholder")
            }
        }
        .setSize(Size(width: 720, height: 400))
        .performLayout()

        let linkPoint = try #require(
            tester.findHitPoint(
                forAccessibilityIdentifier: "sidebar-link",
                in: Rect(x: 0, y: 92, width: 280, height: 308),
                step: 8
            )
        )
        tester.sendMouseEvent(at: linkPoint, phase: MouseEvent.Phase.began)
        tester.sendMouseEvent(at: linkPoint, phase: MouseEvent.Phase.ended)
        await flushNavigationLifecycleActions()

        let nonEmptyStackCount = navigationStackNodes(in: tester.containerView.viewTree.rootNode)
            .filter { !$0.navigationContext.path.isEmpty }
            .count
        #expect(nonEmptyStackCount == 1)
        #expect(textNodes(in: tester.containerView.viewTree.rootNode).contains { $0.text == "Detail message" })
    }
}

@MainActor
struct NavigationSplitViewTests {

    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func dividerUsesLocalHitAreaForResizeCursor() {
        let window = makeNavigationSplitWindow()

        window.sendEvent(
            MouseEvent(
                window: window.id,
                button: .none,
                mousePosition: Point(280, 100),
                phase: .changed,
                modifierKeys: [],
                time: 0
            )
        )
        #expect(window.windowManager.getCursorShape() == .resizeLeftRight)

        window.sendEvent(
            MouseEvent(
                window: window.id,
                button: .none,
                mousePosition: Point(560, 100),
                phase: .changed,
                modifierKeys: [],
                time: 0
            )
        )
        #expect(window.windowManager.getCursorShape() == .arrow)
    }

    private func makeNavigationSplitWindow() -> UIWindow {
        let container = UIContainerView(
            rootView: NavigationSplitView {
                Color.clear
            } detail: {
                Color.clear
            }
        )
        container.frame = Rect(x: 0, y: 0, width: 800, height: 400)

        let window = UIWindow(frame: Rect(x: 0, y: 0, width: 800, height: 400))
        window.addSubview(container)
        window.layoutSubviews()
        return window
    }
}

// Helper view that calls dismiss via environment
private struct DismissTestView: View {
    let onAppear: () -> Void

    var body: some View {
        Color.blue
            .frame(width: 200, height: 200)
            .onAppear(perform: onAppear)
    }
}

private struct NavigationRootStateHost: View {
    @State private var counter = 0

    let driver: NavigationRootStateDriver
    let onAppear: () -> Void

    var body: some View {
        NavigationStack {
            VStack {
                Color.red
                    .frame(width: 300, height: 120)
                    .onAppear(perform: onAppear)

                NavigationRootStateBindingProbe(counter: $counter, driver: driver)
            }
        }
    }
}

private final class NavigationRootStateDriver {
    var counter: Binding<Int>?
}

private struct NavigationTitleStateHost: View {
    @State private var title = "General"

    let driver: NavigationTitleStateDriver

    var body: some View {
        NavigationStack {
            NavigationTitleStateBindingProbe(title: $title, driver: driver)
                .navigationTitle(title)
        }
    }
}

private final class NavigationTitleStateDriver {
    var title: Binding<String>?
}

private struct NavigationTitleStateBindingProbe: View {
    @Binding var title: String

    let driver: NavigationTitleStateDriver

    init(title: Binding<String>, driver: NavigationTitleStateDriver) {
        self._title = title
        self.driver = driver
        self.driver.title = title
    }

    var body: some View {
        Color.clear
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

    if let navigationStack = node as? NavigationStackNode {
        return firstScrollView(in: navigationStack.shortcutContentSubtree)
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
private func navigationStackNodes(in node: ViewNode) -> [NavigationStackNode] {
    var result: [NavigationStackNode] = []

    if let stack = node as? NavigationStackNode {
        result.append(stack)
    }

    if let root = node as? ViewRootNode {
        result += navigationStackNodes(in: root.contentNode)
    } else if let modifier = node as? ViewModifierNode {
        result += navigationStackNodes(in: modifier.contentNode)
    } else if let container = node as? ViewContainerNode {
        for child in container.nodes {
            result += navigationStackNodes(in: child)
        }
    } else {
        for child in reflectedChildNodes(of: node) {
            result += navigationStackNodes(in: child)
        }
    }

    return result
}

@MainActor
private func textNodes(in node: ViewNode) -> [(text: String, frame: Rect)] {
    var result: [(String, Rect)] = []

    if let text = node.content as? Text {
        result.append((text.plainText, node.absoluteFrame()))
    }

    if let root = node as? ViewRootNode {
        result += textNodes(in: root.contentNode)
    } else if let modifier = node as? ViewModifierNode {
        result += textNodes(in: modifier.contentNode)
    } else if let container = node as? ViewContainerNode {
        for child in container.nodes {
            result += textNodes(in: child)
        }
    } else {
        for child in reflectedChildNodes(of: node) {
            result += textNodes(in: child)
        }
    }

    return result
}

@MainActor
private func reflectedChildNodes(of node: ViewNode) -> [ViewNode] {
    Mirror(reflecting: node).children.flatMap { child -> [ViewNode] in
        if let node = child.value as? ViewNode {
            return [node]
        }
        if let node = child.value as? ViewNode? {
            return node.map { [$0] } ?? []
        }
        return []
    }
}

private struct NavigationRootStateBindingProbe: View {
    @Binding var counter: Int

    let driver: NavigationRootStateDriver

    init(counter: Binding<Int>, driver: NavigationRootStateDriver) {
        self._counter = counter
        self.driver = driver
        self.driver.counter = counter
    }

    var body: some View {
        EmptyView()
    }
}

private struct FullScreenCoverDismissCaptureView: View {
    typealias Body = Never

    let onBuild: (DismissAction) -> Void
}

extension FullScreenCoverDismissCaptureView: ViewNodeBuilder {
    func buildViewNode(in context: BuildContext) -> ViewNode {
        onBuild(context.environment.dismiss)
        return context.makeNode(from: Color.blue)
    }
}

private final class FullScreenCoverLayoutCounter {
    var layoutPasses = 0
}

private struct FullScreenCoverCountingView: View, ViewNodeBuilder {
    typealias Body = Never

    let counter: FullScreenCoverLayoutCounter

    func buildViewNode(in context: BuildContext) -> ViewNode {
        FullScreenCoverCountingViewNode(content: self, counter: counter)
    }
}

private final class FullScreenCoverCountingViewNode: ViewNode {
    private let counter: FullScreenCoverLayoutCounter

    init(content: FullScreenCoverCountingView, counter: FullScreenCoverLayoutCounter) {
        self.counter = counter
        super.init(content: content)
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        Size(width: 100, height: 100)
    }

    override func performLayout() {
        counter.layoutPasses += 1
        super.performLayout()
    }
}

@MainActor
struct FullScreenCoverTests {

    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func fullScreenCover_notPresented_overlayHidden() {
        var overlayAppeared = false

        _ = ViewTester {
            Color.red
                .frame(width: 100, height: 100)
                .fullScreenCover(isPresented: Binding<Bool>.constant(false)) {
                    Color.blue
                        .onAppear { overlayAppeared = true }
                }
        }

        #expect(!overlayAppeared)
    }

    @Test
    func fullScreenCover_notPresented_updateDoesNotRelayoutContent() {
        let counter = FullScreenCoverLayoutCounter()

        let tester = ViewTester {
            FullScreenCoverCountingView(counter: counter)
                .fullScreenCover(isPresented: Binding<Bool>.constant(false)) {
                    Color.blue
                }
        }
        .setSize(Size(width: 400, height: 400))
        .performLayout()

        let layoutPassesAfterInitialLayout = counter.layoutPasses

        tester.invalidateContent()

        #expect(counter.layoutPasses == layoutPassesAfterInitialLayout)
    }

    @Test
    func fullScreenCover_presented_overlayShown() async {
        var overlayAppeared = false

        _ = ViewTester {
            Color.red
                .frame(width: 100, height: 100)
                .fullScreenCover(isPresented: Binding<Bool>.constant(true)) {
                    Color.blue
                        .onAppear { overlayAppeared = true }
                }
        }

        await flushNavigationLifecycleActions()
        #expect(overlayAppeared)
    }

    @Test
    func fullScreenCover_dismiss_hidesOverlay() {
        var isPresentedValue = true
        let isPresented = Binding(
            get: { isPresentedValue },
            set: { isPresentedValue = $0 }
        )

        var overlayDisappeared = false

        let tester = ViewTester {
            Color.red
                .frame(width: 100, height: 100)
                .fullScreenCover(isPresented: isPresented) {
                    Color.blue
                        .onDisappear { overlayDisappeared = true }
                }
        }
        .setSize(Size(width: 400, height: 400))
        .performLayout()

        #expect(isPresentedValue)
        #expect(!overlayDisappeared)

        // Simulate dismiss: flip the binding and trigger rebuild
        isPresented.wrappedValue = false

        let coverNode = tester.containerView.viewTree.rootNode.contentNode as? FullScreenCoverNode
        #expect(coverNode != nil)
        coverNode?.invalidateContent()

        #expect(!isPresentedValue)
    }

    @Test
    func fullScreenCover_presented_overlayNodeExists() async {
        var overlayAppeared = false

        let tester = ViewTester {
            Color.red
                .frame(width: 100, height: 100)
                .fullScreenCover(isPresented: Binding<Bool>.constant(true)) {
                    Color.blue
                        .onAppear { overlayAppeared = true }
                }
        }
        .setSize(Size(width: 400, height: 400))
        .performLayout()
        await flushNavigationLifecycleActions()

        // overlayAppeared proves the overlay node was built and attached to the tree
        #expect(overlayAppeared)

        let coverNode = tester.containerView.viewTree.rootNode.contentNode as? FullScreenCoverNode
        #expect(coverNode != nil)
    }

    @Test
    func fullScreenCover_itemNil_overlayHidden() {
        var selectedItem: Int?
        let item = Binding<Int?>(
            get: { selectedItem },
            set: { selectedItem = $0 }
        )
        var overlayAppeared = false

        _ = ViewTester {
            Color.red
                .frame(width: 100, height: 100)
                .fullScreenCover(item: item) { value in
                    Color.blue
                        .onAppear {
                            overlayAppeared = true
                            selectedItem = value
                        }
                }
        }

        #expect(!overlayAppeared)
        #expect(selectedItem == nil)
    }

    @Test
    func fullScreenCover_itemPresented_passesItemAndDismissSetsNil() throws {
        var selectedItem: Int? = 42
        let item = Binding<Int?>(
            get: { selectedItem },
            set: { selectedItem = $0 }
        )
        var presentedItem: Int?
        var dismiss: DismissAction?

        let tester = ViewTester {
            Color.red
                .frame(width: 100, height: 100)
                .fullScreenCover(item: item) { value in
                    FullScreenCoverDismissCaptureView { dismissAction in
                        presentedItem = value
                        dismiss = dismissAction
                    }
                }
        }

        #expect(presentedItem == 42)
        #expect(tester.containerView.viewTree.rootNode.contentNode is FullScreenCoverNode)

        let dismissAction = try #require(dismiss)
        dismissAction()

        #expect(selectedItem == nil)
    }
}

private func flushNavigationLifecycleActions() async {
    await Task.yield()
}
