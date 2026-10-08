import Math

extension TextEditorViewNode {
    func drawTouchSelectionHandles(in context: inout UIGraphicsContext) {
        // The first row's top knob belongs in the padding, outside the glyph clip.
        context.clip(to: visualAbsoluteFrame()) { clipped in
            var clipped = clipped
            touchSelectionHandles()?.draw(in: &clipped, color: environment.accentColor)
        }
    }

    func selectionCaretRect(at offset: Int) -> Rect {
        let pointSize = resolvedFontPointSize()
        let height = lineHeight(for: pointSize)
        let rect = textRect()
        let font = resolvedFontForRendering()
        if wrapsLines {
            let rows = wrappedRows()
            let index = wrappedRowIndex(forOffset: offset, rows: rows)
            let row = rows[index]
            return Rect(
                x: rect.minX + caretXOffset(forColumn: offset - row.line.startOffset, in: row.line.text, font: font, pointSize: pointSize),
                y: rect.minY + Float(index) * height,
                width: Constants.caretLineWidth,
                height: height
            )
        }
        let lines = lines()
        let position = position(forOffset: offset, lines: lines)
        return Rect(
            x: rect.minX + caretXOffset(forColumn: position.column, in: lines[position.line].text, font: font, pointSize: pointSize),
            y: rect.minY + Float(displayRow(forLine: position.line)) * height,
            width: Constants.caretLineWidth,
            height: height
        )
    }

    func touchSelectionHandles() -> TextSelectionHandles? {
        guard isFocused, hasSelection, showsTouchSelectionHandles else {
            return nil
        }
        return TextSelectionHandles(
            start: TextSelectionHandle(edge: .start, caret: selectionCaretRect(at: selectionRange.lowerBound)),
            end: TextSelectionHandle(edge: .end, caret: selectionCaretRect(at: selectionRange.upperBound))
        )
    }
}
