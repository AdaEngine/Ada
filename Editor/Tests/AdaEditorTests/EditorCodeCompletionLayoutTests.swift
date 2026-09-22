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
            caretRect: Rect(x: 128, y: 82, width: 1.5, height: 18),
            itemCount: 40
        )
        let contentHeight = frame.height - EditorCompletionPopupLayout.verticalPadding * 2

        #expect(frame.minY >= EditorCompletionPopupLayout.viewportInset)
        #expect(frame.maxY <= viewport.height - EditorCompletionPopupLayout.viewportInset)
        #expect(contentHeight.truncatingRemainder(dividingBy: EditorCompletionPopupLayout.rowHeight) == 0)
    }

    @Test("completion moves above a caret near the bottom edge")
    func completionUsesSpaceAboveBottomCaret() {
        let caretRect = Rect(x: 128, y: 104, width: 1.5, height: 18)
        let frame = EditorCompletionPopupLayout.frame(
            viewportSize: Size(width: 440, height: 140),
            caretRect: caretRect,
            itemCount: 2
        )

        #expect(frame.maxY <= caretRect.minY)
    }

    @Test("completion tracks the visible caret after document scrolling")
    func completionTracksScrolledCaret() {
        let caretRect = Rect(x: 240, y: 74, width: 1.5, height: 18)
        let frame = EditorCompletionPopupLayout.frame(
            viewportSize: Size(width: 900, height: 700),
            caretRect: caretRect,
            itemCount: 3
        )

        #expect(frame.minX == caretRect.minX)
        #expect(frame.minY == caretRect.maxY)
    }
}
