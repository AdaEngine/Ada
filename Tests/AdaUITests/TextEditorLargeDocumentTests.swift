import AdaInput
@testable import AdaPlatform
import AdaText
@_spi(Internal) @testable import AdaUI
import AdaUtils
import Foundation
import Math
import Testing

/// Large documents must not rescan the whole text or every token span for each keystroke or visible row.
@MainActor
struct TextEditorLargeDocumentTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func tokenSpansAreIndexedOncePerSpanSet() throws {
        let lineCount = 2_000
        let text = (0..<lineCount).map { "let value\($0) = \($0) // comment" }.joined(separator: "\n")
        // Columns are deliberately out of order, with a zero-length span the code view never draws.
        let spans = (0..<lineCount).flatMap { line in
            [
                TextEditorTokenSpan(line: line, startColumn: 4, length: 5, color: .blue),
                TextEditorTokenSpan(line: line, startColumn: 0, length: 3, color: .red),
                TextEditorTokenSpan(line: line, startColumn: 2, length: 0, color: .green),
            ]
        }
        let tester = ViewTester {
            TextEditor(text: .constant(text), tokenSpans: spans)
                .font(.system(size: 14))
                .frame(width: 900, height: 400)
        }
        .setSize(Size(width: 900, height: 400))
        .performLayout()
        let node = try #require(tester.sendMouseEvent(at: Point(100, 28), phase: .began) as? TextEditorViewNode)
        tester.sendMouseEvent(at: Point(100, 28), phase: .ended)
        let root = tester.containerView.viewTree.rootNode

        for _ in 0..<4 {
            root.draw(with: UIGraphicsContext())
        }
        #expect(node.tokenSpanIndexBuilds == 1)
        #expect(node.tokenSpans(forLine: 1_500).map(\.startColumn) == [0, 4])
        #expect(node.documentOrderTokenSpans(forLine: 1_500).map(\.startColumn) == [4, 0, 2])
        #expect(node.tokenSpans(forLine: lineCount).isEmpty)

        node.tokenSpans = [TextEditorTokenSpan(line: 7, startColumn: 1, length: 2, color: .white)]
        root.draw(with: UIGraphicsContext())
        #expect(node.tokenSpanIndexBuilds == 2)
        #expect(node.tokenSpans(forLine: 7).map(\.startColumn) == [1])
        #expect(node.tokenSpans(forLine: 1_500).isEmpty)
    }

    @Test
    func lineTableConvertsOffsetsAcrossGraphemesAndEmptyLines() throws {
        let text = "a👩🏽‍💻b\n\ne\u{301}x\n\t👍🏾 last\n"
        let tester = ViewTester {
            TextEditor(text: .constant(text))
                .font(.system(size: 14))
                .frame(width: 500, height: 200)
        }
        .setSize(Size(width: 500, height: 200))
        .performLayout()
        let node = try #require(tester.sendMouseEvent(at: Point(100, 28), phase: .began) as? TextEditorViewNode)
        tester.sendMouseEvent(at: Point(100, 28), phase: .ended)

        let characters = Array(text)
        let lines = node.lines()
        #expect(lines.map(\.text) == ["a👩🏽‍💻b", "", "e\u{301}x", "\t👍🏾 last", ""])
        #expect(lines.map(\.length) == lines.map(\.text.count))
        #expect(node.textCharacterCount == characters.count)

        var line = 0
        var column = 0
        for offset in 0...characters.count {
            let position = node.position(forOffset: offset, lines: lines)
            #expect(position == TextEditorViewNode.TextPosition(line: line, column: column), "offset \(offset)")
            #expect(node.offset(line: line, column: column, lines: lines) == offset)
            #expect(node.index(forOffset: offset) == text.index(text.startIndex, offsetBy: offset), "offset \(offset)")
            if offset < characters.count, characters[offset] == "\n" {
                line += 1
                column = 0
            } else {
                column += 1
            }
        }
        #expect(node.position(forOffset: characters.count + 10, lines: lines) == node.position(forOffset: characters.count, lines: lines))
        #expect(node.index(forOffset: -3) == text.startIndex)
    }

    @Test
    func typingInLargeDocumentSplitsLinesOncePerEdit() throws {
        var text = (0..<5_000).map { "    let value\($0) = \($0)" }.joined(separator: "\n")
        let tester = ViewTester {
            TextEditor(text: Binding(get: { text }, set: { text = $0 }))
                .font(.system(size: 14))
                .frame(width: 900, height: 400)
        }
        .setSize(Size(width: 900, height: 400))
        .performLayout()
        let node = try #require(tester.sendMouseEvent(at: Point(100, 28), phase: .began) as? TextEditorViewNode)
        tester.sendMouseEvent(at: Point(100, 28), phase: .ended)
        let lines = node.lines()
        let target = node.offset(line: 2_500, column: 4, lines: lines)
        node.setSelection(to: target)
        let root = tester.containerView.viewTree.rootNode

        let builds = node.lineCacheBuilds
        tester.sendTextInput("x")
        _ = tester.performLayout()
        root.draw(with: UIGraphicsContext())
        #expect(node.lineCacheBuilds == builds + 1)
        #expect(node.lines()[2_500].text == "    xlet value2500 = 2500")
        #expect(node.caretOffset == target + 1)

        tester.sendDeleteBackward()
        #expect(node.lines()[2_500].text == "    let value2500 = 2500")
        #expect(text == (0..<5_000).map { "    let value\($0) = \($0)" }.joined(separator: "\n"))
    }
}
