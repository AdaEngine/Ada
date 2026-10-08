//
//  GridLayoutTests.swift
//  AdaEngine
//

import Testing
@testable import AdaPlatform
@testable import AdaUI
import Math

@MainActor
struct GridLayoutTests {

    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func gridPlacesFixedChildrenInRows() throws {
        let tester = ViewTester {
            Grid(columns: 2, horizontalSpacing: 10, verticalSpacing: 20) {
                fixedGridCell("a")
                fixedGridCell("b")
                fixedGridCell("c")
            }
        }
        .setSize(Size(width: 250, height: 200))
        .performLayout()

        let a = try #require(tester.findNodeByAccessibilityIdentifier("a"))
        let b = try #require(tester.findNodeByAccessibilityIdentifier("b"))
        let c = try #require(tester.findNodeByAccessibilityIdentifier("c"))

        #expect(a.frame.origin == Point(0, 0))
        #expect(b.frame.origin == Point(130, 0))
        #expect(c.frame.origin == Point(0, 70))
    }

    @Test
    func gridReportsWrappedHeight() {
        let tester = ViewTester {
            Grid(columns: 3, horizontalSpacing: 5, verticalSpacing: 7) {
                fixedGridCell("a")
                fixedGridCell("b")
                fixedGridCell("c")
                fixedGridCell("d")
            }
        }
        .setSize(Size(width: 310, height: 200))
        .performLayout()

        let size = tester.containerView.viewTree.rootNode.contentNode.sizeThatFits(
            ProposedViewSize(width: 310, height: nil)
        )

        #expect(size.width == 310)
        #expect(size.height == 107)
    }
}

@MainActor
private func fixedGridCell(_ id: String) -> some View {
    EmptyView()
        .frame(width: 40, height: 50)
        .accessibilityIdentifier(id)
}
