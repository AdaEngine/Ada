import AdaInput
import Math
import Testing
@testable import AdaPlatform
@testable import AdaUI

#if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)

@MainActor
@Suite("Text editor keyboard navigation")
struct TextEditorKeyboardNavigationTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test("Command Shift Left stays on a whitespace-only line")
    func commandShiftLeftDoesNotCrossNewlineOnBlankLine() throws {
        let text = "first line\n    \nlast line"
        let (tester, node) = try Self.makeFocusedEditor(text: text)
        let caret = node.offset(line: 1, column: 4, lines: node.lines())
        node.selectionAnchor = caret
        node.selectionHead = caret

        tester.sendKeyEvent(.arrowLeft, modifiers: [.main, .shift])

        let lineStart = node.offset(line: 1, column: 0, lines: node.lines())
        #expect(node.selectionRange == lineStart..<caret)
        #expect(node.selectedText() == "    ")
    }

    @Test("Command Shift Left handles indentation, Unicode, and punctuation")
    func commandShiftLeftHandlesIndentedUnicodeContent() throws {
        let text = "привет, мир!\n\t  世界!?尾\nnext"
        let (tester, node) = try Self.makeFocusedEditor(text: text)
        let line = node.lines()[1]
        let caret = line.startOffset + line.text.count
        node.selectionAnchor = caret
        node.selectionHead = caret

        tester.sendKeyEvent(.arrowLeft, modifiers: [.main, .shift])

        let lineStart = line.startOffset
        #expect(node.selectionRange == lineStart..<caret)
        #expect(node.selectedText() == "\t  世界!?尾")
    }

    @Test("Repeated Command Shift Left preserves the original anchor")
    func repeatedCommandShiftLeftStopsAtSameLineStart() throws {
        let (tester, node) = try Self.makeFocusedEditor(text: "prefix\n  value")
        let caret = node.offset(line: 1, column: 7, lines: node.lines())
        node.selectionAnchor = caret
        node.selectionHead = caret

        tester.sendKeyEvent(.arrowLeft, modifiers: [.main, .shift])
        let firstRange = node.selectionRange
        let firstAnchor = node.selectionAnchor
        tester.sendKeyEvent(.arrowLeft, modifiers: [.main, .shift])

        #expect(node.selectionAnchor == firstAnchor)
        #expect(node.selectionRange == firstRange)
        #expect(node.caretOffset == node.offset(line: 1, column: 0, lines: node.lines()))
    }

    @Test("Command Shift Right stops before the following newline")
    func commandShiftRightDoesNotCrossNewline() throws {
        let text = "first\n  value  \nlast"
        let (tester, node) = try Self.makeFocusedEditor(text: text)
        let line = node.lines()[1]
        node.selectionAnchor = line.startOffset
        node.selectionHead = line.startOffset

        tester.sendKeyEvent(.arrowRight, modifiers: [.main, .shift])

        let lineEnd = line.startOffset + line.text.count
        #expect(node.selectionRange == line.startOffset..<lineEnd)
        #expect(node.selectedText() == "  value  ")
    }

    @Test("Command arrows move the caret to logical line boundaries")
    func commandArrowsMoveCaretWithoutSelection() throws {
        let (tester, node) = try Self.makeFocusedEditor(text: "first\n  value")
        let caret = node.offset(line: 1, column: 4, lines: node.lines())
        node.selectionAnchor = caret
        node.selectionHead = caret

        tester.sendKeyEvent(.arrowLeft, modifiers: [.main])
        #expect(node.caretOffset == node.offset(line: 1, column: 0, lines: node.lines()))

        tester.sendKeyEvent(.arrowRight, modifiers: [.main])
        #expect(node.caretOffset == node.offset(line: 1, column: 7, lines: node.lines()))
        #expect(!node.hasSelection)
    }

    @Test("Option Shift Left continues to select one word")
    func optionShiftLeftUsesWordBoundary() throws {
        let (tester, node) = try Self.makeFocusedEditor(text: "alpha beta")
        node.selectionAnchor = node.text.count
        node.selectionHead = node.text.count

        tester.sendKeyEvent(.arrowLeft, modifiers: [.alt, .shift])

        #expect(node.selectedText() == "beta")
        #expect(node.selectionRange == 6..<10)
    }

    private static func makeFocusedEditor(text: String) throws -> (ViewTester<AnyView>, TextEditorViewNode) {
        var content = text
        let tester = ViewTester {
            AnyView(TextEditor(
                text: Binding(
                    get: { content },
                    set: { content = $0 }
                )
            )
            .font(.system(size: 12))
            .frame(width: 360, height: 160))
        }
        .setSize(Size(width: 380, height: 180))
        .performLayout()

        let node = try #require(
            tester.sendMouseEvent(at: Point(100, 28), phase: .began) as? TextEditorViewNode
        )
        tester.sendMouseEvent(at: Point(100, 28), phase: .ended, time: 0.01)
        return (tester, node)
    }
}

#endif
