//
//  TextEditorViewNode+Gutter.swift
//  AdaEngine
//

import AdaText
import AdaUtils
import Math

extension TextEditorViewNode {
    func gutterViewportRect() -> Rect {
        let viewport = self.viewportChromeRect()
        return Rect(
            x: viewport.minX + Constants.horizontalInset,
            y: viewport.minY,
            width: self.gutterInset,
            height: viewport.height
        )
    }

    func drawPinnedGutter(
        in context: inout UIGraphicsContext,
        visibleRows: Range<Int>,
        displayedLines: [Int],
        lines: [LineInfo],
        contentRect: Rect,
        lineHeight: Float,
        pointSize: Float,
        font: Font?,
        caretLine: Int,
        colors: TextEditorColors
    ) {
        let viewport = self.viewportChromeRect()
        let gutter = self.gutterViewportRect()
        let gutterEdge = gutter.maxX
        let foldRanges = self.foldRanges()
        context.drawRect(
            Rect(x: viewport.minX, y: viewport.minY, width: gutterEdge - viewport.minX, height: viewport.height),
            color: colors.background
        )

        for row in visibleRows {
            let lineIndex = displayedLines[row]
            let rowY = contentRect.minY + Float(row) * lineHeight
            if self.isFocused, caretLine == lineIndex {
                context.drawRect(
                    Rect(x: viewport.minX, y: rowY, width: gutterEdge - viewport.minX, height: lineHeight),
                    color: colors.currentLineBackground
                )
            }
            if self.sourceInteraction?.executionLine == lineIndex {
                context.drawRect(
                    Rect(x: viewport.minX, y: rowY, width: gutterEdge - viewport.minX, height: lineHeight),
                    color: self.environment.accentColor.opacity(0.20)
                )
                context.drawRect(
                    Rect(x: gutterEdge - 5, y: rowY, width: 3, height: lineHeight),
                    color: self.environment.accentColor
                )
            }

            if let marker = self.sourceInteraction?.lineMarkers.first(where: { $0.line == lineIndex }) {
                context.drawEllipse(
                    in: Rect(x: gutter.minX, y: rowY + (lineHeight - 10) * 0.5, width: 10, height: 10),
                    color: marker.color,
                    thickness: marker.isFilled ? 1 : 0.22
                )
            } else if self.hoveredGutterLine == lineIndex,
                let color = self.sourceInteraction?.gutterHoverColor {
                context.drawEllipse(
                    in: Rect(x: gutter.minX, y: rowY + (lineHeight - 10) * 0.5, width: 10, height: 10),
                    color: color,
                    thickness: 0.22
                )
            }

            if foldRanges[lineIndex] != nil {
                let center = Point(gutter.minX + 24, rowY + lineHeight * 0.5)
                let color = colors.gutter
                if self.collapsedFoldLines.contains(lineIndex) {
                    context.drawLine(start: Point(center.x - 3, -center.y + 5), end: Point(center.x + 2, -center.y), lineWidth: 2.5, color: color)
                    context.drawLine(start: Point(center.x + 2, -center.y), end: Point(center.x - 3, -center.y - 5), lineWidth: 2.5, color: color)
                } else {
                    context.drawLine(start: Point(center.x - 5, -center.y + 2), end: Point(center.x, -center.y - 3), lineWidth: 2.5, color: color)
                    context.drawLine(start: Point(center.x, -center.y - 3), end: Point(center.x + 5, -center.y + 2), lineWidth: 2.5, color: color)
                }
            }

            if let font {
                let number = String(lineIndex + 1)
                self.drawString(
                    number,
                    font: font,
                    color: colors.gutter,
                    in: &context,
                    at: Point(gutter.minX + Constants.gutterWidth - Float(number.count) * self.characterAdvance(for: pointSize), rowY)
                )
            }
        }

        let ruleX = gutterEdge - Constants.gutterSpacing * 0.5
        context.drawLine(
            start: Point(ruleX, -viewport.minY),
            end: Point(ruleX, -viewport.maxY),
            lineWidth: 1,
            color: colors.gutterRule
        )

        if viewport.minX > 0.5 {
            let shadowOpacity = min(1, viewport.minX / Constants.gutterShadowWidth) * 0.25
            context.drawLinearGradient(
                ResolvedLinearGradient(
                    startPoint: .leading,
                    endPoint: .trailing,
                    stops: [
                        Gradient.Stop(color: .black.opacity(shadowOpacity), location: 0),
                        Gradient.Stop(color: .black.opacity(0), location: 1),
                    ]
                ),
                in: Rect(
                    x: gutterEdge,
                    y: viewport.minY,
                    width: min(Constants.gutterShadowWidth, max(0, viewport.maxX - gutterEdge)),
                    height: viewport.height
                )
            )
        }
    }

    func drawIndentationMarkers(
        in context: inout UIGraphicsContext,
        line: LineInfo,
        rowY: Float,
        pointSize: Float,
        font: Font
    ) {
        let indentation = Array(line.text.prefix { $0 == " " || $0 == "\t" })
        guard !indentation.isEmpty else { return }
        let centerY = rowY + self.lineHeight(for: pointSize) * 0.5
        let color = self.environment.textEditorColors.gutter.opacity(0.75)
        var column = 0
        while column < indentation.count {
            let isTab = indentation[column] == "\t"
            let isSpaceGroup = !isTab && column + 4 <= indentation.count && indentation[column..<(column + 4)].allSatisfy { $0 == " " }
            let step = isTab ? 1 : (isSpaceGroup ? 4 : 1)
            let startX = self.textRect().minX + self.caretXOffset(forColumn: column, in: line.text, font: font, pointSize: pointSize)
            let endX = self.textRect().minX + self.caretXOffset(forColumn: column + step, in: line.text, font: font, pointSize: pointSize)
            if isTab || isSpaceGroup {
                let arrowX = max(startX + 3, endX - 8)
                context.drawLine(start: Point(max(startX + 2, arrowX - 5), -centerY), end: Point(arrowX, -centerY), lineWidth: 1.8, color: color)
                context.drawLine(start: Point(arrowX - 3, -centerY + 3), end: Point(arrowX, -centerY), lineWidth: 1.8, color: color)
                context.drawLine(start: Point(arrowX, -centerY), end: Point(arrowX - 3, -centerY - 3), lineWidth: 1.8, color: color)
                context.drawLine(start: Point(endX - 3, -centerY + 4), end: Point(endX - 3, -centerY - 4), lineWidth: 1.8, color: color)
            } else {
                context.drawRect(Rect(x: (startX + endX) * 0.5, y: centerY, width: 1.8, height: 1.8), color: color)
            }
            column += step
        }
    }
}
