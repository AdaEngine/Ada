//
//  AspectRatioModifierTests.swift
//  AdaEngine
//
//  Created by OpenAI on 08.05.2026.
//

import Testing
@testable import AdaUI
@testable import AdaPlatform
import Math

@MainActor
struct AspectRatioModifierTests {

    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func aspectRatioFitConstrainsProposal() {
        let tester = ViewTester {
            AspectRatioProbe(idealSize: Size(width: 10, height: 10))
                .aspectRatio(2, contentMode: .fit)
        }

        let size = tester.containerView.viewTree.rootNode.contentNode.sizeThatFits(
            ProposedViewSize(width: 100, height: 100)
        )

        #expect(size.width == 100)
        #expect(size.height == 50)
    }

    @Test
    func aspectRatioFillConstrainsProposal() {
        let tester = ViewTester {
            AspectRatioProbe(idealSize: Size(width: 10, height: 10))
                .aspectRatio(2, contentMode: .fill)
        }

        let size = tester.containerView.viewTree.rootNode.contentNode.sizeThatFits(
            ProposedViewSize(width: 100, height: 100)
        )

        #expect(size.width == 200)
        #expect(size.height == 100)
    }

    @Test
    func aspectRatioUsesIdealSizeWhenProposalIsUnspecified() {
        let tester = ViewTester {
            AspectRatioProbe(idealSize: Size(width: 10, height: 10))
                .aspectRatio(2, contentMode: .fit)
        }

        let size = tester.containerView.viewTree.rootNode.contentNode.sizeThatFits(.unspecified)

        #expect(size.width == 10)
        #expect(size.height == 5)
    }

    @Test
    func scaledToFitUsesIdealAspectRatio() {
        let tester = ViewTester {
            AspectRatioProbe(idealSize: Size(width: 120, height: 60))
                .scaledToFit()
        }

        let size = tester.containerView.viewTree.rootNode.contentNode.sizeThatFits(
            ProposedViewSize(width: 100, height: 100)
        )

        #expect(size.width == 100)
        #expect(size.height == 50)
    }

    @Test
    func scaledToFillUsesIdealAspectRatio() {
        let tester = ViewTester {
            AspectRatioProbe(idealSize: Size(width: 120, height: 60))
                .scaledToFill()
        }

        let size = tester.containerView.viewTree.rootNode.contentNode.sizeThatFits(
            ProposedViewSize(width: 100, height: 100)
        )

        #expect(size.width == 200)
        #expect(size.height == 100)
    }

    @Test
    func aspectRatioFillCanOverflowFixedFrame() throws {
        let tester = ViewTester {
            AspectRatioProbe(idealSize: Size(width: 10, height: 10))
                .aspectRatio(2, contentMode: .fill)
                .frame(width: 100, height: 100)
        }
        .setSize(Size(width: 100, height: 100))
        .performLayout()

        let frameNode = try #require(tester.containerView.viewTree.rootNode.contentNode as? FrameViewNode)
        let aspectNode = frameNode.contentNode

        #expect(aspectNode.frame.size.width == 200)
        #expect(aspectNode.frame.size.height == 100)
        #expect(aspectNode.frame.origin.x == -50)
        #expect(aspectNode.frame.origin.y == 0)
    }
}

private struct AspectRatioProbe: View, ViewNodeBuilder {
    typealias Body = Never

    let idealSize: Size
    var body: Never { fatalError() }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        AspectRatioProbeNode(idealSize: idealSize, content: self)
    }
}

private final class AspectRatioProbeNode: ViewNode {
    let idealSize: Size

    init<Content: View>(idealSize: Size, content: Content) {
        self.idealSize = idealSize
        super.init(content: content)
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        proposal.replacingUnspecifiedDimensions(by: idealSize)
    }
}
