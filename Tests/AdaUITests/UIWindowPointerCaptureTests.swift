import AdaInput
@testable import AdaPlatform
@testable import AdaUI
import Math
import Testing

@MainActor
struct UIWindowPointerCaptureTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test("mouse drag stays with its pressed view across sibling views and outside the window")
    func mouseCapture() {
        let (window, first, second) = makeWindow()
        send(window, .began, Point(20, 20))
        send(window, .changed, Point(150, 20))
        send(window, .ended, Point(350, 20))
        #expect(first.mousePhases == [.began, .changed, .ended])
        #expect(second.mousePhases.isEmpty)
        send(window, .began, Point(150, 20))
        send(window, .ended, Point(150, 20))
        #expect(second.mousePhases == [.began, .ended])
    }

    @Test("hover recovers a missed release and scroll does not steal a captured drag")
    func hoverAndScroll() {
        let (window, first, second) = makeWindow()
        send(window, .began, Point(20, 20))
        send(window, .changed, Point(150, 20), button: .scrollWheel)
        #expect(first.mousePhases == [.began])
        #expect(second.mousePhases == [.changed])
        send(window, .changed, Point(150, 20), button: .none)
        #expect(first.mousePhases == [.began, .ended])
        #expect(second.mousePhases == [.changed, .changed])
    }

    @Test("removed views cannot retain pointer capture")
    func removedResponder() {
        let (window, first, second) = makeWindow()
        send(window, .began, Point(20, 20))
        first.removeFromParentView()
        send(window, .changed, Point(150, 20))
        #expect(first.mousePhases == [.began])
        #expect(second.mousePhases == [.changed])
    }

    @Test("touch drag keeps its responder through cancellation")
    func touchCapture() {
        let (window, first, second) = makeWindow()
        for (phase, point) in [(TouchEvent.Phase.began, Point(20, 20)), (.moved, Point(150, 20)), (.cancelled, Point(350, 20))] {
            window.sendEvent(TouchEvent(window: window.id, location: point, phase: phase, time: 0))
        }
        #expect(first.touchPhases == [.began, .moved, .cancelled])
        #expect(second.touchPhases.isEmpty)
        window.sendEvent(TouchEvent(window: window.id, location: Point(150, 20), phase: .began, time: 1))
        #expect(second.touchPhases == [.began])
    }

    private func makeWindow() -> (UIWindow, PointerCaptureView, PointerCaptureView) {
        let window = UIWindow(frame: Rect(x: 0, y: 0, width: 240, height: 100))
        let first = PointerCaptureView(frame: Rect(x: 0, y: 0, width: 100, height: 100))
        let second = PointerCaptureView(frame: Rect(x: 100, y: 0, width: 140, height: 100))
        window.addSubview(first)
        window.addSubview(second)
        window.layoutSubviews()
        return (window, first, second)
    }

    private func send(_ window: UIWindow, _ phase: MouseEvent.Phase, _ point: Point, button: MouseButton = .left) {
        window.sendEvent(MouseEvent(window: window.id, button: button, mousePosition: point, phase: phase, modifierKeys: [], time: 0))
    }
}

@MainActor
private final class PointerCaptureView: UIView {
    var mousePhases: [MouseEvent.Phase] = []
    var touchPhases: [TouchEvent.Phase] = []

    override func onMouseEvent(_ event: MouseEvent) {
        mousePhases.append(event.phase)
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        touchPhases.append(contentsOf: touches.map(\.phase))
    }
}
