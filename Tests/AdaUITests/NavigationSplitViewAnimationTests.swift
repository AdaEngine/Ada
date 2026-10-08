//
//  NavigationSplitViewAnimationTests.swift
//  AdaEngine
//
//  Created by Codex on 01.05.2026.
//

import Testing
@testable import AdaPlatform
@testable import AdaUI
import AdaUtils
import Math

@MainActor
struct NavigationSplitViewAnimationTests {

    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func animatedColumnVisibilityMovesSidebarInAndOut() {
        let capture = CapturedNavigationSplitVisibility()
        let tester = ViewTester(rootView: AnimatedSidebarSplitView(capture: capture))
            .setSize(Size(width: 720, height: 320))
            .performLayout()

        func sidebarIsHittableNearLeadingEdge() -> Bool {
            tester.findHitPoint(
                forAccessibilityIdentifier: "animated-sidebar",
                in: Rect(x: 1, y: 1, width: 96, height: 96),
                step: 12
            ) != nil
        }

        #expect(sidebarIsHittableNearLeadingEdge())

        capture.visibility.wrappedValue = .detailOnly

        #expect(sidebarIsHittableNearLeadingEdge())

        tester.advanceFrame(deltaTime: 0)
        tester.advanceFrame(deltaTime: 0.5)
        #expect(sidebarIsHittableNearLeadingEdge())

        tester.advanceFrame(deltaTime: 0.5)
        #expect(!sidebarIsHittableNearLeadingEdge())

        capture.visibility.wrappedValue = .all
        tester.advanceFrame(deltaTime: 0)
        tester.advanceFrame(deltaTime: 0.5)
        #expect(sidebarIsHittableNearLeadingEdge())

        tester.advanceFrame(deltaTime: 0.5)
        #expect(sidebarIsHittableNearLeadingEdge())
    }

    @Test
    func compactDetailWithoutExplicitNavigationStackShowsBackButton() {
        let capture = CapturedNavigationSplitColumn()
        let tester = ViewTester(rootView: CompactSplitNavigationHost(capture: capture))
            .setSize(Size(width: 390, height: 640))
            .performLayout()

        #expect(capture.column.wrappedValue == .detail)
        #expect(
            tester.findHitPoint(
                forAccessibilityIdentifier: "AdaUI.NavigationSplitView.backButton",
                in: Rect(x: 0, y: 0, width: 96, height: 96),
                step: 8
            ) != nil
        )
    }

    @Test
    func compactDetailInstallsBackButtonIntoNearestNavigationStack() {
        let capture = CapturedNavigationSplitColumn()
        let tester = ViewTester(rootView: CompactSplitNavigationStackHost(capture: capture))
            .setSize(Size(width: 390, height: 640))
            .performLayout()

        #expect(capture.column.wrappedValue == .detail)
        #expect(
            tester.findHitPoint(
                forAccessibilityIdentifier: "AdaUI.NavigationSplitView.backButton",
                in: Rect(x: 0, y: 0, width: 96, height: 96),
                step: 8
            ) != nil
        )

        tester.sendMouseEvent(at: Point(36, 36), phase: .began)
        tester.sendMouseEvent(at: Point(36, 36), phase: .ended)

        #expect(capture.column.wrappedValue == .sidebar)
        tester.advanceFrame(deltaTime: 1)
        #expect(
            tester.findHitPoint(
                forAccessibilityIdentifier: "compact-sidebar",
                in: Rect(x: 0, y: 0, width: 390, height: 640),
                step: 24
            ) != nil
        )
    }

    @Test
    func compactDetailEdgeSwipeReturnsToSidebar() {
        let capture = CapturedNavigationSplitColumn()
        let tester = ViewTester(rootView: CompactSplitNavigationHost(capture: capture))
            .setSize(Size(width: 390, height: 640))
            .performLayout()

        #expect(capture.column.wrappedValue == .detail)

        tester.sendMouseEvent(at: Point(8, 240), phase: .began)
        tester.sendMouseEvent(at: Point(132, 244), button: .left, phase: .changed)
        tester.sendMouseEvent(at: Point(132, 244), phase: .ended)

        #expect(capture.column.wrappedValue == .sidebar)
    }
}

@MainActor
private final class CapturedNavigationSplitVisibility {
    var visibility: Binding<NavigationSplitViewVisibility>!
}

@MainActor
private final class CapturedNavigationSplitColumn {
    var column: Binding<NavigationSplitViewColumn>!
}

private struct AnimatedSidebarSplitView: View {
    let capture: CapturedNavigationSplitVisibility
    @State private var visibility = NavigationSplitViewVisibility.all

    var body: some View {
        let _ = capture.visibility = $visibility.animation(.linear(duration: 1))

        NavigationSplitView(columnVisibility: $visibility) {
            Color.red
                .onTap { }
                .accessibilityIdentifier("animated-sidebar")
        } detail: {
            Color.blue
                .onTap { }
                .accessibilityIdentifier("animated-detail")
        }
    }
}

private struct CompactSplitNavigationHost: View {
    let capture: CapturedNavigationSplitColumn
    @State private var compactColumn = NavigationSplitViewColumn.detail

    var body: some View {
        let _ = capture.column = $compactColumn.animation(.linear(duration: 1))

        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            Color.red
                .onTap { }
                .accessibilityIdentifier("compact-sidebar")
        } detail: {
            Color.blue
                .onTap { }
                .accessibilityIdentifier("compact-detail")
        }
    }
}

private struct CompactSplitNavigationStackHost: View {
    let capture: CapturedNavigationSplitColumn
    @State private var compactColumn = NavigationSplitViewColumn.detail

    var body: some View {
        let _ = capture.column = $compactColumn.animation(.linear(duration: 1))

        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            Color.red
                .onTap { }
                .accessibilityIdentifier("compact-sidebar")
        } detail: {
            NavigationStack {
                Color.blue
                    .onTap { }
                    .accessibilityIdentifier("compact-detail")
            }
        }
    }
}
