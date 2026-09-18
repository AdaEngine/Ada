import Math
import Testing

@testable import AdaEditor

@Suite("Editor code completion layout")
struct EditorCodeCompletionLayoutTests {
    @Test("small iPad viewport keeps only complete completion rows")
    func smallViewportDoesNotClipCompletionRows() {
        let viewport = Size(width: 440, height: 120)
        let frame = EditorCompletionPopupLayout.frame(
            viewportSize: viewport,
            caretPosition: EditorSourceLocation(line: 4, character: 8),
            fontSize: 12,
            itemCount: 40
        )
        let contentHeight = frame.height - EditorCompletionPopupLayout.verticalPadding * 2

        #expect(frame.minY >= EditorCompletionPopupLayout.viewportInset)
        #expect(frame.maxY <= viewport.height - EditorCompletionPopupLayout.viewportInset)
        #expect(contentHeight.truncatingRemainder(dividingBy: EditorCompletionPopupLayout.rowHeight) == 0)
    }

    @Test("completion moves above a caret near the bottom edge")
    func completionUsesSpaceAboveBottomCaret() {
        let caretTop = Float(18) + Float(4) * max(18, Float(12) * 1.45)
        let frame = EditorCompletionPopupLayout.frame(
            viewportSize: Size(width: 440, height: 140),
            caretPosition: EditorSourceLocation(line: 4, character: 8),
            fontSize: 12,
            itemCount: 2
        )

        #expect(frame.maxY <= caretTop)
    }
}
