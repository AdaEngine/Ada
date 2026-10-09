//
//  TabContainerTests.swift
//  AdaEngine
//

import Testing
@testable import AdaUI
@testable import AdaPlatform
import AdaInput
import AdaUtils
import Math

private struct TabContainerMarkerKey: EnvironmentKey {
    static let defaultValue: String = "default"
}

private extension EnvironmentValues {
    var tabContainerTestMarker: String {
        get { self[TabContainerMarkerKey.self] }
        set { self[TabContainerMarkerKey.self] = newValue }
    }
}

private struct TabContainerMarkerView: View {
    @AdaUI.Environment(\.tabContainerTestMarker) private var marker
    let baseID: String

    var body: some View {
        Text(marker)
            .accessibilityIdentifier("\(baseID)-\(marker)")
    }
}

private struct TabContainerTestStyle: TabViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach(configuration.tabs) { tab in
                    Button(tab.label ?? "TAB", action: tab.action)
                }
            }
            configuration.content
        }
    }
}

private struct CollapsibleTabContainerTestStyle: TabViewStyle {
    let showsTabBar: Bool

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if showsTabBar {
            TabContainerTestStyle().makeBody(configuration: configuration)
                .accessibilityIdentifier("home-tab-bar")
        } else {
            configuration.content
        }
    }
}

private struct CollapsibleTabContainerRoot: View {
    @State var showsTabBar = true
    @State var selected = 0

    var body: some View {
        TabView(selection: $selected) {
            Tab("Studio", value: 0) {
                Text("Workspace").accessibilityIdentifier("retained-workspace")
            }
            Tab("Community", value: 1) {
                Text("Community").accessibilityIdentifier("retained-community")
            }
        }
        .tabViewStyle(CollapsibleTabContainerTestStyle(showsTabBar: showsTabBar))
    }
}

private struct StatefulTabContainerTestStyle: TabViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        StatefulTabContainerTestBody(configuration: configuration)
    }
}

private struct StatefulTabContainerTestBody: View {
    let configuration: TabViewStyleConfiguration
    @State private var interactionCount = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(configuration.tabs) { tab in
                    Button {
                        tab.action()
                        interactionCount += 1
                    } label: {
                        Text(tab.label ?? "TAB")
                            .frame(width: 80, height: 40)
                    }
                    .accessibilityIdentifier("stateful-tab-\(tab.id)")
                }
            }
            if let selected = configuration.tabs.first(where: { $0.isSelected }) {
                Text("Selected \(selected.id), interactions \(interactionCount)")
                    .accessibilityIdentifier("stateful-selected-\(selected.id)")
            }
            configuration.content
        }
    }
}

private enum TabContainerEnvironmentValue: Hashable {
    case first
    case second
}

private final class TabContainerEnvironmentModel {
    var selected: TabContainerEnvironmentValue = .first
    var marker: String = "A"
}

private struct TabContainerEnvironmentRoot: View {
    let model: TabContainerEnvironmentModel

    var body: some View {
        TabView(
            selection: Binding(get: { model.selected }, set: { model.selected = $0 })
        ) {
            Tab("First", value: TabContainerEnvironmentValue.first) {
                TabContainerMarkerView(baseID: "first-marker")
            }
            Tab("Second", value: TabContainerEnvironmentValue.second) {
                TabContainerMarkerView(baseID: "second-marker")
            }
        }
        .tabViewStyle(TabContainerTestStyle())
        .environment(\.tabContainerTestMarker, model.marker)
        .frame(width: 320, height: 120)
    }
}

@MainActor
struct TabContainerTests {
    init() async throws {
        try Application.prepareForTest()
    }

    // MARK: - TabView switching

    @Test
    func customStyleCanHideAndRestoreTabBarWithoutLosingContent() async throws {
        let root = CollapsibleTabContainerRoot()
        let tester = ViewTester(rootView: root)
            .setSize(Size(width: 320, height: 480))
            .performLayout()
        let workspace = try #require(tester.findNodeByAccessibilityIdentifier("retained-workspace"))

        for showsTabBar in [false, true, false, true] {
            root.showsTabBar = showsTabBar
            await Task.yield()
            tester.advanceFrame(deltaTime: 0.4).performLayout()
            #expect((tester.findNodeByAccessibilityIdentifier("home-tab-bar") != nil) == showsTabBar)
            #expect(tester.findNodeByAccessibilityIdentifier("retained-workspace") === workspace)
            #expect(workspace.owner === tester.containerView)
            #expect(workspace.parent != nil)
            var ancestor = workspace
            while let parent = ancestor.parent { ancestor = parent }
            #expect(ancestor === tester.containerView.viewTree.rootNode)
        }

        root.selected = 1
        await Task.yield()
        tester.advanceFrame(deltaTime: 0.4).performLayout()
        #expect(tester.findNodeByAccessibilityIdentifier("retained-community") != nil)
    }

    @Test
    func tabView_switchesContentOnSelectionChange() {
        final class Model { var selected: Int = 0 }
        let model = Model()

        let tester = ViewTester {
            TabView(
                selection: Binding(get: { model.selected }, set: { model.selected = $0 })
            ) {
                Tab("", value: 0) {
                    Text("Content A")
                        .accessibilityIdentifier("content-a")
                        .frame(width: 200, height: 40)
                }
                Tab("", value: 1) {
                    Text("Content B")
                        .accessibilityIdentifier("content-b")
                        .frame(width: 200, height: 40)
                }
            }
            .frame(width: 300, height: 120)
        }
        .setSize(Size(width: 320, height: 140))
        .performLayout()

        let rect = Rect(origin: .zero, size: Size(width: 320, height: 140))
        let before = tester.collectHitAccessibilityIdentifiers(in: rect)
        #expect(before.contains("content-a"))
        #expect(!before.contains("content-b"))

        model.selected = 1
        tester.invalidateContent().performLayout()
        tester.advanceFrame(deltaTime: 0.3)

        let after = tester.collectHitAccessibilityIdentifiers(in: rect)
        #expect(!after.contains("content-a"))
        #expect(after.contains("content-b"))
    }

    @Test
    func tabView_sizeFitsBarAndContent_topPosition() {
        final class Model { var selected: Int = 0 }
        let model = Model()

        let tester = ViewTester {
            TabView(
                selection: Binding(get: { model.selected }, set: { model.selected = $0 })
            ) {
                Tab("One", value: 0) { HStack(alignment: .center, spacing: 0) {}.frame(width: 100, height: 60) }
                Tab("Two", value: 1) { HStack(alignment: .center, spacing: 0) {}.frame(width: 100, height: 60) }
                Tab("Three", value: 2) { HStack(alignment: .center, spacing: 0) {}.frame(width: 100, height: 60) }
            }
            .frame(width: 260, height: 100)
        }
        .setSize(Size(width: 280, height: 120))
        .performLayout()

        #expect(model.selected == 0)
    }

    // MARK: - Tab label formats

    @Test
    func tabView_supportsTextOnlyTab() {
        final class Model { var selected: Int = 0 }
        let model = Model()

        let tester = ViewTester {
            TabView(
                selection: Binding(get: { model.selected }, set: { model.selected = $0 })
            ) {
                Tab("Alpha", value: 0) {
                    Text("Alpha content").accessibilityIdentifier("alpha-content")
                }
            }
            .frame(width: 300, height: 120)
        }
        .setSize(Size(width: 320, height: 140))
        .performLayout()

        let rect = Rect(origin: .zero, size: Size(width: 320, height: 140))
        let ids = tester.collectHitAccessibilityIdentifiers(in: rect)
        if ids.isEmpty {
            Issue.record(
                Comment(
                    rawValue: tester
                        .containerView
                        .viewTree
                        .rootNode
                        .debugDescription()
                )
            )
        }
        #expect(ids.contains("alpha-content"))
    }

    // MARK: - Position variants

    @Test
    func tabView_bottomPosition_rendersCorrectly() {
        final class Model { var selected: Int = 0 }
        let model = Model()

        let tester = ViewTester {
            TabView(
                selection: Binding(get: { model.selected }, set: { model.selected = $0 })
            ) {
                Tab("A", value: 0) {
                    Text("Content A").accessibilityIdentifier("content-bottom-a")
                }
                Tab("B", value: 1) {
                    Text("Content B").accessibilityIdentifier("content-bottom-b")
                }
            }
            .tabViewPosition(.bottom)
            .frame(width: 300, height: 120)
        }
        .setSize(Size(width: 320, height: 140))
        .performLayout()

        let rect = Rect(origin: .zero, size: Size(width: 320, height: 140))
        let ids = tester.collectHitAccessibilityIdentifiers(in: rect)
        #expect(ids.contains("content-bottom-a"))
    }

    @Test
    func tabView_leftPosition_rendersCorrectly() {
        final class Model { var selected: Int = 0 }
        let model = Model()

        let tester = ViewTester {
            TabView(
                selection: Binding(get: { model.selected }, set: { model.selected = $0 })
            ) {
                Tab("A", value: 0) {
                    Text("Content A").accessibilityIdentifier("content-left-a")
                }
                Tab("B", value: 1) {
                    Text("Content B").accessibilityIdentifier("content-left-b")
                }
            }
            .tabViewPosition(.left)
            .frame(width: 400, height: 200)
        }
        .setSize(Size(width: 420, height: 220))
        .performLayout()

        let rect = Rect(origin: .zero, size: Size(width: 420, height: 220))
        let ids = tester.collectHitAccessibilityIdentifiers(in: rect)
        #expect(ids.contains("content-left-a"))
    }

    @Test
    func tabView_rightPosition_rendersCorrectly() {
        final class Model { var selected: Int = 0 }
        let model = Model()

        let tester = ViewTester {
            TabView(
                selection: Binding(get: { model.selected }, set: { model.selected = $0 })
            ) {
                Tab("A", value: 0) {
                    Text("Content A").accessibilityIdentifier("content-right-a")
                }
                Tab("B", value: 1) {
                    Text("Content B").accessibilityIdentifier("content-right-b")
                }
            }
            .tabViewPosition(.right)
            .frame(width: 400, height: 200)
        }
        .setSize(Size(width: 420, height: 220))
        .performLayout()

        let rect = Rect(origin: .zero, size: Size(width: 420, height: 220))
        let ids = tester.collectHitAccessibilityIdentifiers(in: rect)
        #expect(ids.contains("content-right-a"))
    }

    // MARK: - TabSection

    @Test
    func tabView_withTabSection_showsFirstTabContent() {
        enum Route: Hashable { case home, inbox, archive }
        final class Model { var selected: Route = .home }
        let model = Model()

        let tester = ViewTester {
            TabView(
                selection: Binding(get: { model.selected }, set: { model.selected = $0 })
            ) {
                Tab("Home", value: Route.home) {
                    Text("Home").accessibilityIdentifier("home-content")
                }
                TabSection("Messages") {
                    Tab("Inbox", value: Route.inbox) {
                        Text("Inbox").accessibilityIdentifier("inbox-content")
                    }
                    Tab("Archive", value: Route.archive) {
                        Text("Archive").accessibilityIdentifier("archive-content")
                    }
                }
            }
            .frame(width: 400, height: 200)
        }
        .setSize(Size(width: 420, height: 220))
        .performLayout()

        let rect = Rect(origin: .zero, size: Size(width: 420, height: 220))
        let before = tester.collectHitAccessibilityIdentifiers(in: rect)
        #expect(before.contains("home-content"))
        #expect(!before.contains("inbox-content"))

        model.selected = .inbox
        tester.invalidateContent().performLayout()
        tester.advanceFrame(deltaTime: 0.3)

        let after = tester.collectHitAccessibilityIdentifiers(in: rect)
        #expect(!after.contains("home-content"))
        #expect(after.contains("inbox-content"))
    }

    // MARK: - Spacer + Divider in tab bar

    @Test
    func tabView_withSpacerAndDivider_rendersContent() {
        final class Model { var selected: Int = 0 }
        let model = Model()

        let tester = ViewTester {
            TabView(
                selection: Binding(get: { model.selected }, set: { model.selected = $0 })
            ) {
                Tab("Main", value: 0) {
                    Text("Main content").accessibilityIdentifier("main-spacer-content")
                }
                Spacer()
                Divider()
                Tab("Settings", value: 1) {
                    Text("Settings").accessibilityIdentifier("settings-spacer-content")
                }
            }
            .tabViewPosition(.left)
            .frame(width: 400, height: 200)
        }
        .setSize(Size(width: 420, height: 220))
        .performLayout()

        let rect = Rect(origin: .zero, size: Size(width: 420, height: 220))
        let ids = tester.collectHitAccessibilityIdentifiers(in: rect)
        #expect(ids.contains("main-spacer-content"))
    }

    @Test
    func customStyledTabView_refreshesEnvironmentWhenReturningToCachedTab() {
        let model = TabContainerEnvironmentModel()
        let tester = ViewTester(rootView: TabContainerEnvironmentRoot(model: model))
        .setSize(Size(width: 320, height: 140))
        .performLayout()

        let rect = Rect(origin: .zero, size: Size(width: 320, height: 140))
        #expect(tester.collectHitAccessibilityIdentifiers(in: rect).contains("first-marker-A"))

        model.selected = .second
        tester.invalidateContent().performLayout()
        tester.advanceFrame(deltaTime: 0.3)
        #expect(tester.collectHitAccessibilityIdentifiers(in: rect).contains("second-marker-A"))

        model.marker = "B"
        tester.invalidateContent().performLayout()
        tester.advanceFrame(deltaTime: 0.3)
        #expect(tester.collectHitAccessibilityIdentifiers(in: rect).contains("second-marker-B"))

        model.selected = .first
        tester.invalidateContent().performLayout()
        tester.advanceFrame(deltaTime: 0.3)
        #expect(tester.collectHitAccessibilityIdentifiers(in: rect).contains("first-marker-B"))
    }

    @Test
    func statefulCustomStyle_updatesSelectionAndKeepsContentDuringInteractions() throws {
        final class Model { var selected = 0 }
        let model = Model()
        let tester = ViewTester {
            TabView(selection: Binding(get: { model.selected }, set: { model.selected = $0 })) {
                Tab("First", value: 0) {
                    Text("First content").accessibilityIdentifier("stateful-content-0")
                }
                Tab("Second", value: 1) {
                    Text("Second content").accessibilityIdentifier("stateful-content-1")
                }
                Tab("Third", value: 2) {
                    Text("Third content").accessibilityIdentifier("stateful-content-2")
                }
            }
            .tabViewStyle(StatefulTabContainerTestStyle())
            .frame(width: 320, height: 180)
        }
        .setSize(Size(width: 320, height: 180))
        .performLayout()

        let rect = Rect(origin: .zero, size: Size(width: 320, height: 180))
        #expect(tester.collectHitAccessibilityIdentifiers(in: rect).contains("stateful-content-0"))
        for selected in [1, 2, 0, 2, 1, 0] {
            let point = try #require(tester.findHitPoint(forAccessibilityIdentifier: "stateful-tab-\(selected)", in: rect))
            tester.sendMouseEvent(at: point, phase: .began)
            tester.sendMouseEvent(at: point, phase: .ended)
            tester.advanceFrame(deltaTime: 0.4).performLayout()

            #expect(model.selected == selected)
            #expect(tester.findNodeByAccessibilityIdentifier("stateful-selected-\(selected)") != nil)
            #expect(tester.collectHitAccessibilityIdentifiers(in: rect).contains("stateful-content-\(selected)"))
        }
    }

    // MARK: - Backward compatibility (deprecated TabContainer)

    @Test
    func tabContainer_deprecated_switchesContent() {
        final class Model { var selected: Int = 0 }
        let model = Model()

        let tester = ViewTester {
            TabContainer(
                ["Alpha", "Beta"],
                selection: Binding(get: { model.selected }, set: { model.selected = $0 })
            ) { index in
                if index == 0 {
                    Text("Content A")
                        .accessibilityIdentifier("legacy-content-a")
                        .frame(width: 200, height: 40)
                } else {
                    Text("Content B")
                        .accessibilityIdentifier("legacy-content-b")
                        .frame(width: 200, height: 40)
                }
            }
            .frame(width: 300, height: 120)
        }
        .setSize(Size(width: 320, height: 140))
        .performLayout()

        let rect = Rect(origin: .zero, size: Size(width: 320, height: 140))
        #expect(tester.collectHitAccessibilityIdentifiers(in: rect).contains("legacy-content-a"))

        model.selected = 1
        tester.invalidateContent().performLayout()
        tester.advanceFrame(deltaTime: 0.3)
        #expect(tester.collectHitAccessibilityIdentifiers(in: rect).contains("legacy-content-b"))
    }
}
