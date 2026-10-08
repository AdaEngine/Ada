import Math
import Testing

@testable import AdaPlatform
@_spi(Internal) @testable import AdaUI

@Suite("Embedded panel hosts", .serialized)
@MainActor
struct EmbeddedPanelHostTests {
    init() throws { try Application.prepareForTest() }

    @Test("Updating host content keeps the node tree, local state, and new action closures")
    func rootUpdatesPreserveState() throws {
        let record = HostedActionRecord()
        let tester = ViewTester(rootView: HostedCounterPanel(tag: "first", record: record))
        let root = tester.containerView.viewTree.rootNode
        try click(tester)
        #expect(record.values == ["first:1"])

        tester.containerView.updateRootView(HostedCounterPanel(tag: "second", record: record))
        tester.performLayout()
        #expect(tester.containerView.viewTree.rootNode === root)
        try click(tester)
        #expect(record.values == ["first:1", "second:2"])
    }

    @Test("Embedded windows use their owner without replacing the process-wide manager")
    func independentManagers() {
        let global = UIWindowManager.shared
        let first = HostedTestWindowManager()
        let second = HostedTestWindowManager()
        let frame = Rect(x: 0, y: 0, width: 320, height: 240)
        let firstWindow = UIWindow(frame: frame, configuration: .init(frame: frame), windowManager: first)
        let secondWindow = UIWindow(frame: frame, configuration: .init(frame: frame), windowManager: second)
        #expect(firstWindow.windowManager === first)
        #expect(secondWindow.windowManager === second)
        #expect(UIWindowManager.shared === global)
        #expect(first.windows[firstWindow.id] === firstWindow)
        #expect(first.windows[secondWindow.id] == nil)
        firstWindow.frame.size = Size(width: 400, height: 300)
        #expect(first.lastSize == Size(width: 400, height: 300))
        #expect(second.lastSize == nil)
    }

    private func click(_ tester: ViewTester<HostedCounterPanel>) throws {
        let node = try #require(tester.findNodeByAccessibilityIdentifier("HostedCounter"))
        let frame = node.visualAbsoluteFrame()
        let center = Point(frame.midX, frame.midY)
        tester.sendMouseEvent(at: center, phase: .began)
        tester.sendMouseEvent(at: center, phase: .ended)
        tester.performLayout()
    }
}

@MainActor
private final class HostedActionRecord {
    var values: [String] = []
}

private struct HostedCounterPanel: View {
    let tag: String
    let record: HostedActionRecord
    @State private var count = 0
    var body: some View {
        Button(action: {
            count += 1
            record.values.append("\(tag):\(count)")
        }) {
            EmptyView().frame(width: 100, height: 40)
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("HostedCounter")
    }
}

@MainActor
private final class HostedTestWindowManager: UIWindowManager {
    var lastSize: Size?
    override func resizeWindow(_: UIWindow, size: Size) { lastSize = size }
}
