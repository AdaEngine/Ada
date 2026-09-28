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
