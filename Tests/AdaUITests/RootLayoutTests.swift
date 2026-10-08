//
//  RootLayoutTests.swift
//  AdaEngineTests
//

import Testing
@testable import AdaUI
@testable import AdaPlatform
import Math

@MainActor
struct RootLayoutTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func customRootViewWithSingleBodyReceivesFullContainerProposal() {
        let tester = ViewTester(rootView: FullScreenRootView())
            .setSize(Size(width: 800, height: 600))
            .performLayout()

        let rootContent = tester.containerView.viewTree.rootNode.contentNode
        let fillNode = tester.findNodeByAccessibilityIdentifier("fill")

        #expect(rootContent.frame == Rect(origin: .zero, size: Size(width: 800, height: 600)))
        #expect(fillNode?.frame == Rect(origin: .zero, size: Size(width: 800, height: 600)))
    }
}

private struct FullScreenRootView: View {
    var body: some View {
        EmptyView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("fill")
    }
}
