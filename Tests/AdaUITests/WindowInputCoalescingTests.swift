@_spi(Internal) @testable import AdaInput
@testable import AdaPlatform
@_spi(AdaEngine) @testable import AdaUI
import AdaUtils
import Math
import Observation
import Testing

@MainActor
@Suite(.serialized)
struct WindowInputCoalescingTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test("An opted-in drag preserves reversals and the final position")
    func coalescedDragPreservesTurningPoints() {
        var positions: [Float] = []
        var release: Float?
        let tester = ViewTester {
            Color.red.frame(width: 240, height: 140)
                .gesture(DragGesture(minimumDistance: 1)
                    .coalescingMouseMoves()
                    .onChanged { positions.append($0.translation.width) }
                    .onEnded { release = $0.translation.width })
        }.setSize(Size(width: 240, height: 140)).performLayout()
        let window = makeWindow(container: tester.containerView)
        var input = Input(gameControllerEngine: nil)
        let events = [
            mouse(in: window, x: 30, phase: .began),
            mouse(in: window, x: 35, phase: .changed),
            mouse(in: window, x: 45, phase: .changed),
            mouse(in: window, x: 60, phase: .changed),
            mouse(in: window, x: 60, phase: .changed),
            mouse(in: window, x: 55, phase: .changed),
            mouse(in: window, x: 50, phase: .changed),
            mouse(in: window, x: 50, phase: .ended)
        ]
        events.forEach { input.receiveEvent($0) }
        input.flushPendingEvents()
        window.sendPendingInput(&input)

        #expect(positions == [5, 30, 30, 20])
        #expect(release == 20)
        #expect(input.getInputEvents().map(\.id) == events.map(\.id))
    }

    @Test("A wheel burst mounts only rows at the final offset")
    func wheelBurstRefreshesFinalViewport() throws {
        var builtRows: Set<Int> = []
        let tester = ViewTester {
            ScrollView {
                LazyVStack(Array(0..<120), id: \.self, spacing: 0, estimatedRowHeight: 20, rowHeight: { _ in 20 }, overscan: 0) { index in
                    recordRow(index, in: &builtRows)
                }
            }
        }.setSize(Size(width: 240, height: 140)).performLayout()
        let window = makeWindow(container: tester.containerView)
        let events = (0..<3).map { index in
            MouseEvent(
                window: window.id,
                button: .scrollWheel,
                scrollDelta: Point(0, -2),
                mousePosition: Point(30, 32),
                phase: .changed,
                modifierKeys: [],
                time: Float(index) / 100
            )
        }
        let scroll = try #require(tester.hitTest(Point(30, 32), event: events[0]) as? ScrollViewNode)
        builtRows.removeAll()

        var input = Input(gameControllerEngine: nil)
        events.forEach { input.receiveEvent($0) }
        input.flushPendingEvents()
        window.sendPendingInput(&input)

        #expect(scroll.contentOffset.y == 600)
        #expect(builtRows.contains(30))
        #expect(!builtRows.contains(10))
        #expect(!builtRows.contains(20))
        #expect(input.getInputEvents().map(\.id) == events.map(\.id))
    }

    @Test("A nested list mounts rows relative to the scroll content origin")
    func nestedListUsesAncestorOrigins() throws {
        let tester = ViewTester {
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 600)
                    LazyVStack(Array(0..<120), id: \.self, spacing: 0, estimatedRowHeight: 20, rowHeight: { _ in 20 }, overscan: 0) { index in
                        Text(verbatim: "Row \(index)").frame(height: 20)
                            .accessibilityIdentifier("NestedRow.\(index)")
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }.setSize(Size(width: 240, height: 140)).performLayout()
        let window = makeWindow(container: tester.containerView)
        let scrollEvent = MouseEvent(
            window: window.id,
            button: .scrollWheel,
            scrollDelta: Point(0, -7),
            mousePosition: Point(30, 32),
            phase: .changed,
            modifierKeys: [],
            time: 0
        )
        let scroll = try #require(tester.hitTest(Point(30, 32), event: scrollEvent) as? ScrollViewNode)
        var input = Input(gameControllerEngine: nil)
        input.receiveEvent(scrollEvent)
        input.flushPendingEvents()
        window.sendPendingInput(&input)

        #expect(scroll.contentOffset.y == 700)
        #expect(tester.findNodeByAccessibilityIdentifier("NestedRow.5") != nil)
        #expect(tester.findNodeByAccessibilityIdentifier("NestedRow.35") == nil)
    }

    @Test("Turning off a mask keeps the button receiving its mouse-up")
    func maskPreservesMouseCapture() throws {
        let state = MaskedButtonState()
        let tester = ViewTester {
            MaskedButton(state: state)
        }.setSize(Size(width: 240, height: 140)).performLayout()
        let window = makeWindow(container: tester.containerView)
        let button = try #require(tester.findNodeByAccessibilityIdentifier("MaskedButton"))
        var input = Input(gameControllerEngine: nil)
        input.receiveEvent(mouse(in: window, x: 30, phase: .began))
        input.flushPendingEvents()
        window.sendPendingInput(&input)

        state.clips = false
        tester.performLayout()
        #expect(tester.findNodeByAccessibilityIdentifier("MaskedButton") === button)

        input.flushPendingEvents()
        input.receiveEvent(mouse(in: window, x: 30, phase: .ended))
        input.flushPendingEvents()
        window.sendPendingInput(&input)
        #expect(state.clicks == 1)
    }

    private func recordRow(_ index: Int, in builtRows: inout Set<Int>) -> some View {
        builtRows.insert(index)
        return Text(verbatim: "Row \(index)").frame(height: 20).id(index)
    }

    private func makeWindow<Content: View>(container: UIContainerView<Content>) -> UIWindow {
        let frame = Rect(x: 0, y: 0, width: 240, height: 140)
        let window = UIWindow(frame: frame, configuration: .init(frame: frame), windowManager: MockUIWindowManager())
        container.frame = frame
        container.bounds = frame
        window.addSubview(container)
        container.layoutIfNeeded()
        return window
    }

    private func mouse(in window: UIWindow, x: Float, phase: MouseEvent.Phase) -> MouseEvent {
        MouseEvent(window: window.id, button: .left, mousePosition: Point(x, 32), phase: phase, modifierKeys: [], time: x)
    }
}

@MainActor
@Observable
private final class MaskedButtonState {
    var clips = true
    var clicks = 0
}

private struct MaskedButton: View {
    let state: MaskedButtonState

    var body: some View {
        Button {
            state.clicks += 1
        } label: {
            Color.red.frame(width: 240, height: 140)
        }
        .accessibilityIdentifier("MaskedButton")
        .mask(RectangleShape(), isEnabled: state.clips)
    }
}
