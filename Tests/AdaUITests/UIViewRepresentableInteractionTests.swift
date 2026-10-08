import AdaInput
import Math
import Testing
@_spi(Internal) @testable import AdaUI

@MainActor
struct UIViewRepresentableInteractionTests {
    @Test
    func reconciliationUpdatesConfigurationWithoutReplacingNativeView() throws {
        let node = UIViewRepresentableNode(representable: ProbeRepresentable(value: 1), content: ProbeRepresentable(value: 1))
        node.performLayout()
        let original = try #require(node.view)
        node.update(from: UIViewRepresentableNode(representable: ProbeRepresentable(value: 2), content: ProbeRepresentable(value: 2)))
        node.performLayout()
        #expect(node.view === original)
        #expect(original.value == 2)
    }

    @Test
    func embeddedViewReceivesLocalCoordinatesAndKeyboardFocus() throws {
        let probe = InputProbeView()
        let tester = ViewTester {
            ProbeRepresentable(value: 0, existing: probe)
                .frame(width: 100, height: 80)
                .padding(30)
        }.setSize(Size(width: 160, height: 140)).performLayout()

        tester.sendMouseEvent(at: Point(45, 55), phase: .began)
        #expect(probe.lastPoint == Point(15, 25))
        tester.sendKeyEvent(.a)
        #expect(probe.keyCount == 1)

        probe.isInteractionEnabled = false
        tester.sendKeyEvent(.a)
        #expect(probe.keyCount == 1)
        tester.sendMouseEvent(at: Point(45, 55), phase: .began)
        #expect(probe.mouseCount == 1)
    }

    @Test
    func compositionScalesCompletedDrawingAndPixelClips() throws {
        var source = UIGraphicsContext()
        source.environment.scaleFactor = 2
        source.translateBy(x: 10, y: -20)
        source.drawRect(Rect(x: 0, y: 0, width: 30, height: 40), color: .red)
        source.pushClipRect(Rect(x: 10, y: 20, width: 30, height: 40))
        let destination = UIGraphicsContext()
        let transform = Transform3D(translation: [100, -50, 0]) * Transform3D(scale: [2, 2, 1])
        destination.drawContents(of: source, transform: transform)
        let commands = destination.getDrawCommands()
        try #require(commands.count == 2)
        guard case let .drawQuad(matrix, _, _) = commands[0],
              case let .pushClipRect(clip) = commands[1] else {
            Issue.record("Expected composed quad and clip")
            return
        }
        #expect(matrix.x.x == 60)
        #expect(abs(matrix.y.y) == 80)
        #expect(clip == Rect(x: 240, y: 180, width: 120, height: 160))
    }
}

@MainActor
private struct ProbeRepresentable: UIViewRepresentable {
    let value: Int
    var existing: InputProbeView?

    func makeUIView(in context: Context) -> InputProbeView { existing ?? InputProbeView() }
    func updateUIView(_ view: InputProbeView, in context: Context) { view.value = value }
}

@MainActor
private final class InputProbeView: UIView {
    var value = 0
    var lastPoint: Point?
    var mouseCount = 0
    var keyCount = 0
    override var acceptsKeyboardFocus: Bool { true }

    override func onMouseEvent(_ event: MouseEvent) {
        lastPoint = event.mousePosition
        mouseCount += 1
    }
    override func onKeyEvent(_ event: KeyEvent) { keyCount += 1 }
}
