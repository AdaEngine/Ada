import AdaText
import AdaUtils
import Foundation
import Math

extension TextEditorViewNode {
    func requestAutofocusIfNeeded() {
        guard environment._textEditorAutofocus, appliedAutofocusRequestID != environment._textEditorFocusRequestID,
              let owner, frame.width > 0, frame.height > 0 else {
            return
        }
        appliedAutofocusRequestID = environment._textEditorFocusRequestID
        owner.enqueueLifecycleAction { [weak self] in
            guard let self, self.parent != nil else {
                return
            }
            self.owner?.requestFocus(for: self)
        }
    }

    struct WrappedRow {
        let line: LineInfo
        let sourceLine: Int
        let startColumn: Int
        let isLastInLine: Bool
    }

    struct WrappedRowsCache {
        let width: Float
        let font: Font?
        let pointSize: Float
        let rows: [WrappedRow]
    }

    /// Visual rows retain source offsets; wrapping never changes the user's text or undo history.
    func wrappedRows(width: Float? = nil) -> [WrappedRow] {
        let width = max(1, (width ?? frame.width) - Constants.horizontalInset * 2 - gutterInset - Constants.caretLineWidth)
        let font = resolvedFontForRendering()
        let pointSize = resolvedFontPointSize()
        if let cache = wrappedRowsCache, cache.width == width, cache.font == font, cache.pointSize == pointSize {
            return cache.rows
        }
        let lines = lines()
        var rows: [WrappedRow] = []
        for lineIndex in displayedLines() {
            let line = lines[lineIndex]
            let characters = Array(line.text)
            let characterStops = layoutCaretStops(for: line.text, font: font, pointSize: pointSize)
            var stops: [Float] = [0]
            for index in characters.indices {
                stops.append(characterStops.flatMap { $0.indices.contains(index + 1) ? $0[index + 1] : nil }
                    ?? Float(stops.count) * characterAdvance(for: pointSize))
            }
            var start = 0
            repeat {
                var end = start
                var wordEnd: Int?
                while end < characters.count {
                    if end > start, stops[end + 1] - stops[start] > width { break }
                    end += 1
                    if characters[end - 1].isWhitespace { wordEnd = end }
                }
                if end < characters.count, let wordEnd, wordEnd > start { end = wordEnd }
                rows.append(WrappedRow(
                    line: LineInfo(text: String(characters[start..<end]), startOffset: line.startOffset + start),
                    sourceLine: lineIndex,
                    startColumn: start,
                    isLastInLine: end == characters.count
                ))
                start = end
            } while start < characters.count
        }
        wrappedRowsCache = WrappedRowsCache(width: width, font: font, pointSize: pointSize, rows: rows)
        return rows
    }

    func wrappedRowIndex(forOffset offset: Int, rows: [WrappedRow]) -> Int {
        for (index, row) in rows.enumerated() {
            let end = row.line.startOffset + row.line.text.count
            if offset < end || (row.isLastInLine && offset == end) {
                return index
            }
        }
        return max(0, rows.count - 1)
    }

    func closestWrappedOffset(to point: Point) -> Int {
        let rows = wrappedRows()
        let pointSize = resolvedFontPointSize()
        let rect = textRect()
        let index = max(0, min(rows.count - 1, Int(max(0, point.y - rect.minY) / lineHeight(for: pointSize))))
        let row = rows[index]
        let column = closestColumn(toX: max(0, point.x - rect.minX), in: row.line.text, font: resolvedFontForRendering(), pointSize: pointSize)
        return row.line.startOffset + column
    }

    func wrappedCaretRect() -> Rect {
        let rows = wrappedRows()
        let index = wrappedRowIndex(forOffset: caretOffset, rows: rows)
        let row = rows[index]
        let pointSize = resolvedFontPointSize()
        let height = lineHeight(for: pointSize)
        return Rect(
            x: textRect().minX + caretXOffset(forColumn: caretOffset - row.line.startOffset, in: row.line.text, font: resolvedFontForRendering(), pointSize: pointSize),
            y: textRect().minY + Float(index) * height,
            width: Constants.caretLineWidth,
            height: height
        )
    }

    func moveWrappedCaretVertically(delta: Int, extendSelection: Bool) {
        let rows = wrappedRows()
        let current = wrappedRowIndex(forOffset: caretOffset, rows: rows)
        let column = preferredColumn ?? caretOffset - rows[current].line.startOffset
        let target = rows[max(0, min(rows.count - 1, current + delta))]
        preferredColumn = column
        moveCaret(to: target.line.startOffset + min(column, target.line.text.count), extendSelection: extendSelection)
    }

    func drawWrappedText(with context: UIGraphicsContext) {
        var context = context
        context.environment = environment
        let colors = environment.textEditorColors
        context.translateBy(x: frame.minX, y: -frame.minY)
        context.drawRect(Rect(origin: .zero, size: frame.size), color: colors.background)
        drawBorder(in: &context, rect: viewportChromeRect(), color: isFocused ? colors.focusedBorder : colors.border)
        let rows = wrappedRows()
        let pointSize = resolvedFontPointSize()
        let height = lineHeight(for: pointSize)
        let font = resolvedFontForRendering()
        let rect = textRect()
        let viewport = viewportChromeRect()
        let first = max(0, Int(max(0, viewport.minY - rect.minY) / height))
        let end = max(0, min(rows.count, Int(((viewport.maxY - rect.minY) / height).rounded(.up)) + 1))
        let caret = wrappedCaretRect()
        context.clip(to: visualAbsoluteContentRect()) { clipped in
            var clipped = clipped
            for index in min(first, end)..<end {
                let row = rows[index]
                let y = rect.minY + Float(index) * height
                if isFocused, caret.minY == y {
                    clipped.drawRect(Rect(x: rect.minX, y: y, width: rect.width, height: height), color: colors.currentLineBackground)
                }
                if isFocused, hasSelection {
                    let lineEnd = row.line.startOffset + row.line.text.count
                    let start = max(selectionRange.lowerBound, row.line.startOffset)
                    let end = min(selectionRange.upperBound, lineEnd + (row.isLastInLine && row.sourceLine < lines().count - 1 ? 1 : 0))
                    if end > start {
                        let left = caretXOffset(forColumn: start - row.line.startOffset, in: row.line.text, font: font, pointSize: pointSize)
                        var right = caretXOffset(forColumn: min(end, lineEnd) - row.line.startOffset, in: row.line.text, font: font, pointSize: pointSize)
                        if end > lineEnd { right += characterAdvance(for: pointSize) }
                        clipped.drawRect(Rect(x: rect.minX + left, y: y, width: min(rect.width - left, max(1, right - left)), height: height), color: colors.selection)
                    }
                }
                if let font {
                    let spans = tokenSpans.filter { $0.line == row.sourceLine }.map { span in
                        TextEditorTokenSpan(line: span.line, startColumn: span.startColumn - row.startColumn, length: span.length, color: span.color, font: span.font)
                    }
                    let attributed = attributedLineText(row.line.text, lineSpans: spans, font: font, fallbackColor: resolvedTextColor())
                    drawAttributedString(attributed, font: font, in: &clipped, at: Point(rect.minX, y))
                    if showsLineNumbers, row.startColumn == 0 {
                        drawString(String(row.sourceLine + 1), font: font, color: colors.gutter, in: &clipped, at: Point(Constants.horizontalInset, y))
                    }
                }
            }
            if text.isEmpty, !placeholder.isEmpty, !isFocused, let font {
                drawString(placeholder, font: font, color: resolvedTextColor().opacity(Constants.placeholderOpacity), in: &clipped, at: rect.origin)
            }
            if isFocused, caretVisible, !hasSelection {
                clipped.drawRect(caret, color: environment.theme.textInsertionPointColor ?? environment.accentColor)
            }
        }
        drawTouchSelectionHandles(in: &context)
    }
}
