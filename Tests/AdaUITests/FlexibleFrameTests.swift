//
//  FlexibleFrameTests.swift
//  AdaEngine
//

import Testing
@testable import AdaUI
@testable import AdaPlatform
import Math

@MainActor
struct FlexibleFrameTests {

    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func frameMinWidthMinHeightExpandMeasuredSize() {
        let tester = ViewTester {
            EmptyView()
                .frame(width: 80, height: 20)
                .frame(minWidth: 100, minHeight: 30)
        }
        .setSize(Size(width: 400, height: 400))
        .performLayout()

        let size = tester.containerView.viewTree.rootNode.contentNode.sizeThatFits(.infinity)
        #expect(size.width == 100)
        #expect(size.height == 30)
    }

    @Test
    func frameMaxWidthClampsMeasuredSize() {
        let tester = ViewTester {
            EmptyView()
                .frame(width: 200, height: 40)
                .frame(maxWidth: 150, maxHeight: 50)
        }
        .setSize(Size(width: 400, height: 400))
        .performLayout()

        let size = tester.containerView.viewTree.rootNode.contentNode.sizeThatFits(.infinity)
        #expect(size.width == 150)
        #expect(size.height == 40)
    }

    @Test
    func frameMaxInfinityExpandsToParentProposal() {
        let tester = ViewTester {
            EmptyView()
                .frame(width: 120, height: 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityIdentifier("flex-frame")
        }
        .setSize(Size(width: 400, height: 300))
        .performLayout()

        let size = tester.containerView.viewTree.rootNode.contentNode.sizeThatFits(
            ProposedViewSize(width: 400, height: 300)
        )

        #expect(size.width == 400)
        #expect(size.height == 300)
    }

    @Test
    func frameMinWidthWithParentProposalKeepsContentAtRequestedMinimum() {
        let tester = ViewTester {
            EmptyView()
                .frame(width: 120, height: 40)
                .frame(minWidth: 900, minHeight: 560, alignment: .topLeading)
        }
        .setSize(Size(width: 100, height: 100))
        .performLayout()

        let size = tester.containerView.viewTree.rootNode.contentNode.sizeThatFits(
            ProposedViewSize(width: 100, height: 100)
        )

        #expect(size.width == 900)
        #expect(size.height == 560)
    }

}
