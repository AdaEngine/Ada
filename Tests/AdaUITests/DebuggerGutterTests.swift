import AdaInput
@testable import AdaPlatform
@_spi(Internal) @testable import AdaUI
import Math
import Testing

@Suite("Debugger source gutter")
@MainActor
struct EditorDebuggerGutterTests {
    init() async throws { try Application.prepareForTest() }

    @Test func consoleFieldSubmitsWithReturn() {
        var text = "frame variable"
        var submitted: [String] = []
        let tester = ViewTester {
            TextField("Command", text: Binding(get: { text }, set: { text = $0 }), onSubmit: { submitted.append(text) })
                .frame(width: 300, height: 40)
        }.setSize(Size(width: 320, height: 60)).performLayout()
        tester.sendMouseEvent(at: Point(100, 28), phase: .began)
        tester.sendMouseEvent(at: Point(100, 28), phase: .ended)
        tester.sendKeyEvent(.enter)
        #expect(submitted == ["frame variable"])
        #expect(text == "frame variable")
    }

    @Test func mouseTogglesCorrectLineWithoutEditing() throws {
        var text = "first\nsecond\nthird"
        var clicked: [Int] = []
        let tester = ViewTester {
            TextEditor(text: Binding(get: { text }, set: { text = $0 }), sourceInteraction: .init(
                lineMarkers: [.init(line: 1, color: .red)],
                executionLine: 1,
                onGutterClick: { clicked.append($0) }
            ))
            .font(.system(size: 12))
            .frame(width: 360, height: 160)
        }.setSize(Size(width: 380, height: 180)).performLayout()
        let node = try #require(tester.hitTest(Point(20, 28), event: MouseEvent(
            window: .empty, button: .left, mousePosition: Point(20, 28), phase: .began, modifierKeys: [], time: 0
        )) as? TextEditorViewNode)
        let local = Point(node.textContentRect().minX + 5, node.textContentRect().minY + node.lineHeight(for: node.resolvedFontPointSize()) * 1.5)
        let point = Point(local.x + node.visualAbsoluteFrame().minX, local.y + node.visualAbsoluteFrame().minY)
        tester.sendMouseEvent(at: point, phase: .began, time: 0)
        tester.sendMouseEvent(at: point, phase: .ended, time: 0.01)
        #expect(clicked == [1])
        #expect(text == "first\nsecond\nthird")
        #expect(node.sourceInteraction?.executionLine == 1)
        #expect(node.sourceInteraction?.lineMarkers.first?.line == 1)
    }

    @Test func mouseHoverShowsProspectiveBreakpointLine() throws {
        var text = "first\nsecond\nthird"
        let tester = ViewTester {
            TextEditor(
                text: Binding(get: { text }, set: { text = $0 }),
                sourceInteraction: .init(gutterHoverColor: .red.opacity(0.4), onGutterClick: { _ in })
            )
            .font(.system(size: 12))
            .frame(width: 360, height: 160)
        }.setSize(Size(width: 380, height: 180)).performLayout()
        let node = try #require(tester.click(at: Point(20, 28)) as? TextEditorViewNode)
        let lineHeight = node.lineHeight(for: node.resolvedFontPointSize())
        let gutterPoint = Point(
            node.visualAbsoluteFrame().minX + node.textContentRect().minX + 5,
            node.visualAbsoluteFrame().minY + node.textContentRect().minY + lineHeight * 1.5
        )

        tester.sendMouseEvent(at: gutterPoint, button: .none, phase: .changed)
        #expect(node.hoveredGutterLine == 1)

        let textPoint = Point(
            node.visualAbsoluteFrame().minX + node.textRect().minX + 20,
            gutterPoint.y
        )
        tester.sendMouseEvent(at: textPoint, button: .none, phase: .changed)
        #expect(node.hoveredGutterLine == nil)
    }

    @Test func touchTogglesOnlyOnReleaseAndCancellationDoesNothing() throws {
        var text = "first\nsecond"
        var clicked: [Int] = []
        let tester = ViewTester {
            TextEditor(text: Binding(get: { text }, set: { text = $0 }), sourceInteraction: .init(onGutterClick: { clicked.append($0) }))
                .font(.system(size: 12))
                .frame(width: 360, height: 160)
        }.setSize(Size(width: 380, height: 180)).performLayout()
        let node = try #require(tester.click(at: Point(20, 28)) as? TextEditorViewNode)
        let point = Point(node.visualAbsoluteFrame().minX + 15, node.visualAbsoluteFrame().minY + 16)
        tester.containerView.onTouchesEvent([TouchEvent(window: .empty, location: point, phase: .began, time: 0)])
        #expect(clicked.isEmpty)
        tester.containerView.onTouchesEvent([TouchEvent(window: .empty, location: point, phase: .ended, time: 0.01)])
        #expect(clicked == [0])
        tester.containerView.onTouchesEvent([TouchEvent(window: .empty, location: point, phase: .began, time: 1)])
        tester.containerView.onTouchesEvent([TouchEvent(window: .empty, location: point, phase: .cancelled, time: 1.01)])
        #expect(clicked == [0])
    }
}
