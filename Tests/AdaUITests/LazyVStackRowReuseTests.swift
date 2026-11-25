import AdaInput
@_spi(AdaEngine) @testable import AdaUI
import Math
import Testing

@MainActor
extension LazyVStackTests {
    @Test
    func scrollReusesDetachedRowsByIDUntilContentChanges() throws {
        var label = "original"
        func makeList() -> some View {
            let snapshot = label
            return ScrollView(.vertical) {
                LazyVStack(Array(0..<30), id: \.self, spacing: 0, rowHeight: { _ in 24 }, overscan: 0) { item in
                    Text("\(snapshot) \(item)")
                        .frame(height: 24)
                        .accessibilityIdentifier("\(snapshot)-\(item)")
                }
                .retainingOffscreenRows(upTo: 12)
            }
        }

        let tester = ViewTester(rootView: makeList()).setSize(Size(width: 120, height: 120)).performLayout()
        let root = tester.containerView.viewTree.rootNode
        let scroll = try #require(scrollNode(in: tester))
        let original = try #require(root.findNodeById(AnyHashable(1)))

        scroll.scrollToViewNodeIfFoundIt(15, anchor: .top)
        #expect(root.findNodeById(AnyHashable(1)) == nil)
        #expect(original.parent == nil)
        scroll.scrollToViewNodeIfFoundIt(0, anchor: .top)
        #expect(root.findNodeById(AnyHashable(1)) === original)

        scroll.scrollToViewNodeIfFoundIt(15, anchor: .top)
        label = "updated"
        tester.containerView.updateRootView(makeList())
        tester.performLayout()
        scroll.scrollToViewNodeIfFoundIt(0, anchor: .top)
        #expect(tester.findNodeByAccessibilityIdentifier("updated-1") != nil)
        #expect(root.findNodeById(AnyHashable(1)) !== original)
    }

    @Test
    func scrollEvictsTheOldestDetachedRows() throws {
        let tester = ViewTester {
            ScrollView(.vertical) {
                LazyVStack(Array(0..<30), id: \.self, spacing: 0, rowHeight: { _ in 24 }, overscan: 0) { _ in
                    EmptyView().frame(height: 24)
                }
                .retainingOffscreenRows(upTo: 1)
            }
        }.setSize(Size(width: 120, height: 120)).performLayout()

        let root = tester.containerView.viewTree.rootNode
        let scroll = try #require(scrollNode(in: tester))
        let oldest = try #require(root.findNodeById(AnyHashable(0)))
        let newest = try #require(root.findNodeById(AnyHashable(5)))
        scroll.scrollToViewNodeIfFoundIt(15, anchor: .top)
        scroll.scrollToViewNodeIfFoundIt(0, anchor: .top)

        #expect(root.findNodeById(AnyHashable(0)) !== oldest)
        #expect(root.findNodeById(AnyHashable(5)) === newest)
    }

    @Test
    func scrollDiscardsRowsWithCapturedTouches() throws {
        var taps: [Int] = []
        let tester = ViewTester {
            ScrollView(.vertical) {
                LazyVStack(Array(0..<30), id: \.self, spacing: 0, rowHeight: { _ in 24 }, overscan: 0) { item in
                    Button(action: { taps.append(item) }) {
                        Text("Row \(item)").frame(width: 120, height: 24)
                    }
                }
                .retainingOffscreenRows(upTo: 12)
            }
        }.setSize(Size(width: 120, height: 120)).performLayout()

        let root = tester.containerView.viewTree.rootNode
        let scroll = try #require(scrollNode(in: tester))
        let original = try #require(root.findNodeById(AnyHashable(0)))
        let point = Point(60, 12)
        let captured = TouchEvent(window: .empty, location: point, phase: .began, time: 0)
        #expect(!(tester.hitTest(point, event: captured) is ScrollViewNode))
        tester.containerView.onTouchesEvent([captured])
        scroll.scrollToViewNodeIfFoundIt(15, anchor: .top)
        scroll.scrollToViewNodeIfFoundIt(0, anchor: .top)

        #expect(root.findNodeById(AnyHashable(0)) !== original)
        let tap = TouchEvent(window: .empty, location: point, phase: .began, time: 1)
        tester.containerView.onTouchesEvent([tap])
        tester.containerView.onTouchesEvent([
            TouchEvent(window: .empty, location: point, phase: .ended, time: 1.02, contactID: tap.contactID)
        ])
        #expect(taps == [0])
    }

    private func scrollNode<Content: View>(in tester: ViewTester<Content>) -> ScrollViewNode? {
        let point = Point(60, 100)
        let hit = tester.sendMouseEvent(at: point, button: .scrollWheel, phase: .began)
        tester.sendMouseEvent(at: point, button: .scrollWheel, phase: .cancelled)
        return hit as? ScrollViewNode
    }
}
