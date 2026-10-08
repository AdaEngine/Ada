import Math
import Testing
@testable import AdaPlatform
@testable import AdaUI

@MainActor
struct LayoutDirectionTests {

    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func rightToLeftResolvesLeadingFrameAlignmentToRightEdge() throws {
        let tester = ViewTester {
            LayoutDirectionProbe(size: Size(width: 40, height: 20))
                .accessibilityIdentifier("child")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .environment(\.layoutDirection, .rightToLeft)
        }
        .setSize(Size(width: 200, height: 100))
        .performLayout()

        let child = try #require(tester.findNodeByAccessibilityIdentifier("child"))
        #expect(tester.containerView.viewTree.rootNode.contentNode.environment.layoutDirection == .rightToLeft)
        #expect(child.parent?.environment.layoutDirection == .rightToLeft)
        #expect(child.absoluteFrame().minX == 160)
    }

    @Test
    func rightToLeftAppliesLeadingPaddingOnRightEdge() throws {
        let tester = ViewTester {
            LayoutDirectionProbe(size: Size(width: 20, height: 20))
                .accessibilityIdentifier("child")
                .padding(.leading, 30)
                .frame(width: 100, height: 40, alignment: .leading)
                .environment(\.layoutDirection, .rightToLeft)
        }
        .setSize(Size(width: 100, height: 40))
        .performLayout()

        let child = try #require(tester.findNodeByAccessibilityIdentifier("child"))
        #expect(child.absoluteFrame().minX == 50)
    }

    @Test
    func rightToLeftHStackStartsWithFirstSubviewAtRightEdge() throws {
        let tester = ViewTester {
            HStack(spacing: 10) {
                LayoutDirectionProbe(size: Size(width: 40, height: 20))
                    .accessibilityIdentifier("first")
                LayoutDirectionProbe(size: Size(width: 20, height: 20))
                    .accessibilityIdentifier("second")
            }
            .frame(width: 100, height: 20, alignment: .leading)
            .environment(\.layoutDirection, .rightToLeft)
        }
        .setSize(Size(width: 100, height: 20))
        .performLayout()

        let first = try #require(tester.findNodeByAccessibilityIdentifier("first"))
        let second = try #require(tester.findNodeByAccessibilityIdentifier("second"))
        #expect(first.absoluteFrame().minX == 60)
        #expect(second.absoluteFrame().minX == 30)
    }
}

private struct LayoutDirectionProbe: View, ViewNodeBuilder {
    typealias Body = Never

    let size: Size

    var body: Never { fatalError() }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        LayoutDirectionProbeNode(size: size, content: self)
    }
}

private final class LayoutDirectionProbeNode: ViewNode {
    let size: Size

    init<Content: View>(size: Size, content: Content) {
        self.size = size
        super.init(content: content)
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        size
    }
}
