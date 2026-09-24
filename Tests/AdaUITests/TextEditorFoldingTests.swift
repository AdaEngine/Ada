import AdaInput
@testable import AdaPlatform
@_spi(Internal) @testable import AdaUI
import Math
import Testing

@Suite("Text editor code folding", .serialized)
@MainActor
struct TextEditorFoldingTests {
    init() async throws { try Application.prepareForTest() }

    @Test func braceBlocksCollapseWithoutChangingSourceLines() throws {
        var text = "func update() {\n    if ready {\n        run()\n    }\n}\nafter()"
        var breakpoints: [Int] = []
        let tester = ViewTester {
            TextEditor(
                text: Binding(get: { text }, set: { text = $0 }),
                sourceInteraction: .init(onGutterClick: { breakpoints.append($0) }),
                foldingStyle: .braces,
                showsIndentationMarkers: true
            )
            .font(.system(size: 12))
            .frame(width: 360, height: 180)
        }.setSize(Size(width: 380, height: 200)).performLayout()
        let node = try #require(tester.hitTest(Point(20, 28), event: MouseEvent(
            window: .empty, button: .left, mousePosition: Point(20, 28), phase: .began, modifierKeys: [], time: 0
        )) as? TextEditorViewNode)

        #expect(node.foldRanges()[0] == 1..<4)
        #expect(node.foldRanges()[1] == 2..<3)
        clickFold(in: tester, node: node, row: 0)
        #expect(node.displayedLines() == [0, 4, 5])
        #expect(breakpoints.isEmpty)
        #expect(text.contains("run()"))

        node.setSelection(to: 0)
        node.moveCaretVertically(delta: 1, extendSelection: false)
        #expect(node.position(forOffset: node.selectionHead, lines: node.lines()).line == 4)
        clickFold(in: tester, node: node, row: 0)
        #expect(node.displayedLines() == Array(0..<6))
        clickFold(in: tester, node: node, row: 1)
        #expect(node.displayedLines() == [0, 1, 3, 4, 5])
    }

    @Test func indentationBlocksAndTabMarkersFollowDisplayedRows() throws {
        var text = "func update():\n\tif ready:\n\t\trun()\n\tnext()\nafter()"
        let tester = ViewTester {
            TextEditor(
                text: Binding(get: { text }, set: { text = $0 }),
                foldingStyle: .indentation,
                showsIndentationMarkers: true
            )
            .font(.system(size: 12))
            .frame(width: 360, height: 180)
        }.setSize(Size(width: 380, height: 200)).performLayout()
        let node = try #require(tester.hitTest(Point(20, 28), event: MouseEvent(
            window: .empty, button: .left, mousePosition: Point(20, 28), phase: .began, modifierKeys: [], time: 0
        )) as? TextEditorViewNode)

        #expect(node.foldRanges()[0] == 1..<4)
        #expect(node.foldRanges()[1] == 2..<3)
        clickFold(in: tester, node: node, row: 1)
        #expect(node.displayedLines() == [0, 1, 3, 4])
        #expect(node.sourceLine(atDisplayRow: 2) == 3)

        var commands = UIGraphicsContext()
        node.drawIndentationMarkers(in: &commands, line: node.lines()[1], rowY: 0, pointSize: 12, font: .system(size: 12))
        #expect(commands.getDrawCommands().contains { command in
            if case .drawLine = command { return true }
            return false
        })

        node.setSelection(to: node.lines()[2].startOffset)
        node.ensureCaretVisibleIfNeeded()
        #expect(node.displayedLines() == Array(0..<5))
    }

    private func clickFold<Content: View>(in tester: ViewTester<Content>, node: TextEditorViewNode, row: Int) {
        let point = Point(
            node.visualAbsoluteFrame().minX + node.gutterViewportRect().minX + 24,
            node.visualAbsoluteFrame().minY + node.textContentRect().minY + (Float(row) + 0.5) * node.lineHeight(for: node.resolvedFontPointSize())
        )
        tester.sendMouseEvent(at: point, phase: .began)
        tester.sendMouseEvent(at: point, phase: .ended)
    }
}
