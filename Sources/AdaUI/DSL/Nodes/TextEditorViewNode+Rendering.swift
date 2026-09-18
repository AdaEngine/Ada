//
//  TextEditorViewNode+Rendering.swift
//  AdaEngine
//
//  Created by Codex on 18.05.2026.
//

import AdaInput
import AdaRender
import AdaText
import AdaUtils
import Foundation
import Math

extension TextEditorViewNode {
    func drawSelectionIfNeeded(
        in context: inout UIGraphicsContext,
        line: LineInfo,
        lineIndex: Int,
        rowY: Float,
        lineHeight: Float,
        pointSize: Float,
        font: Font?,
        lineCount: Int
    ) {
        guard self.isFocused, self.hasSelection else {
            return
        }

        let range = self.selectionRange
        let lineStart = line.startOffset
        let lineEnd = line.startOffset + line.text.count
        let includesTrailingNewline = lineIndex < lineCount - 1
        let selectableEnd = includesTrailingNewline ? lineEnd + 1 : lineEnd
        let start = max(range.lowerBound, lineStart)
        let end = min(range.upperBound, selectableEnd)

        guard end > start else {
            return
        }

        let characterAdvance = self.characterAdvance(for: pointSize)
        let textRect = self.textRect()
        let startColumn = max(0, min(start - lineStart, line.text.count))
        let endColumn = end > lineEnd ? line.text.count + 1 : max(0, min(end - lineStart, line.text.count))
        let startX = textRect.minX + self.caretXOffset(forColumn: startColumn, in: line.text, font: font, pointSize: pointSize)
        let endX =
            textRect.minX
            + {
                if end > lineEnd {
                    return self.caretXOffset(forColumn: line.text.count, in: line.text, font: font, pointSize: pointSize) + characterAdvance
                }

                return self.caretXOffset(forColumn: endColumn, in: line.text, font: font, pointSize: pointSize)
            }()

        context.drawRect(
            Rect(x: startX, y: rowY, width: max(characterAdvance, endX - startX), height: lineHeight),
            color: self.environment.textEditorColors.selection
        )
    }

    func drawSourceHighlightsIfNeeded(
        in context: inout UIGraphicsContext,
        line: LineInfo,
        lineIndex: Int,
        rowY: Float,
        lineHeight: Float,
        pointSize: Float,
        font: Font?
    ) {
        guard let sourceInteraction else {
            return
        }

        let accentColor = self.environment.accentColor.opacity(0.72)
        for sourceRange in sourceInteraction.highlightedRanges {
            drawSourceUnderline(
                sourceRange,
                color: accentColor,
                in: &context,
                line: line,
                lineIndex: lineIndex,
                rowY: rowY,
                lineHeight: lineHeight,
                pointSize: pointSize,
                font: font
            )
        }

        if let hoveredRange = sourceInteraction.hoveredRange,
            !sourceInteraction.highlightedRanges.contains(hoveredRange) {
            drawSourceUnderline(
                hoveredRange,
                color: accentColor,
                in: &context,
                line: line,
                lineIndex: lineIndex,
                rowY: rowY,
                lineHeight: lineHeight,
                pointSize: pointSize,
                font: font
            )
        }

        for highlight in sourceInteraction.sourceHighlights {
            drawSourceUnderline(
                highlight.range,
                color: highlight.color,
                in: &context,
                line: line,
                lineIndex: lineIndex,
                rowY: rowY,
                lineHeight: lineHeight,
                pointSize: pointSize,
                font: font
            )
        }
    }

    private func drawSourceUnderline(
        _ sourceRange: TextEditorSourceRange,
        color: Color,
        in context: inout UIGraphicsContext,
        line: LineInfo,
        lineIndex: Int,
        rowY: Float,
        lineHeight: Float,
        pointSize: Float,
        font: Font?
    ) {
        guard
            let columns = Self.sourceUnderlineColumns(
                for: sourceRange,
                lineIndex: lineIndex,
                lineLength: line.text.count
            )
        else {
            return
        }

        let characterAdvance = self.characterAdvance(for: pointSize)
        let textRect = self.textRect()
        let startX = textRect.minX + self.caretXOffset(forColumn: columns.start, in: line.text, font: font, pointSize: pointSize)
        let endX = textRect.minX + self.caretXOffset(forColumn: columns.end, in: line.text, font: font, pointSize: pointSize)
        let highlightRect = Rect(
            x: startX,
            y: rowY + max(0, lineHeight - 3),
            width: max(characterAdvance, endX - startX),
            height: 2
        )
        context.drawRect(highlightRect, color: color)
    }

    static func sourceUnderlineColumns(
        for sourceRange: TextEditorSourceRange,
        lineIndex: Int,
        lineLength: Int
    ) -> (start: Int, end: Int)? {
        guard lineIndex >= sourceRange.start.line, lineIndex <= sourceRange.end.line else {
            return nil
        }

        let startColumn = lineIndex == sourceRange.start.line ? sourceRange.start.column : 0
        let requestedEndColumn = lineIndex == sourceRange.end.line ? sourceRange.end.column : lineLength
        let clampedStart = max(0, min(startColumn, lineLength))
        let clampedEnd = max(clampedStart, min(requestedEndColumn, lineLength))
        return (clampedStart, clampedEnd)
    }

    func drawString(_ string: String, font: Font, color: Color, in context: inout UIGraphicsContext, at point: Point) {
        guard !string.isEmpty else {
            return
        }

        var attributes = TextAttributeContainer()
        attributes.font = font
        attributes.foregroundColor = color
        self.drawAttributedString(AttributedText(string, attributes: attributes), font: font, in: &context, at: point)
    }

    func drawAttributedString(_ string: AttributedText, font: Font, in context: inout UIGraphicsContext, at point: Point) {
        guard !string.text.isEmpty else {
            return
        }

        let lineHeight = self.lineHeight(for: Float(font.pointSize))
        let layout = self.cachedTextLayout(for: string, lineHeight: lineHeight)

        let verticalOffset = Self.verticalTextOffset(for: layout, height: lineHeight)
        context.translateBy(x: point.x, y: -(point.y) + verticalOffset)
        for line in layout.textLines {
            for run in line {
                for glyph in run {
                    context.draw(glyph)
                }
            }
        }
        context.translateBy(x: -point.x, y: point.y - verticalOffset)
    }

    private func cachedTextLayout(for text: AttributedText, lineHeight: Float) -> TextLayoutManager {
        let key = TextLayoutCacheKey(text: text, lineHeight: lineHeight)
        self.textLayoutCacheAccess &+= 1

        if var cached = self.textLayoutCache[key] {
            cached.lastAccess = self.textLayoutCacheAccess
            self.textLayoutCache[key] = cached
            self.textLayoutCacheHits += 1
            return cached.layout
        }

        let layout = TextLayoutManager()
        var container = TextContainer(
            text: text,
            textAlignment: .leading,
            lineBreakMode: .byCharWrapping,
            lineSpacing: 0,
            allowsShaping: false
        )
        container.numberOfLines = 1
        layout.setTextContainer(container)
        layout.fitToSize(Size(width: .infinity, height: lineHeight))

        self.textLayoutCacheMisses += 1
        self.textLayoutCache[key] = CachedTextLayout(
            layout: layout,
            lastAccess: self.textLayoutCacheAccess
        )
        self.pruneTextLayoutCacheIfNeeded()
        return layout
    }

    private func pruneTextLayoutCacheIfNeeded() {
        let maximumEntryCount = 384
        let targetEntryCount = 320
        guard self.textLayoutCache.count > maximumEntryCount else {
            return
        }

        let staleKeys = self.textLayoutCache
            .sorted { $0.value.lastAccess < $1.value.lastAccess }
            .prefix(self.textLayoutCache.count - targetEntryCount)
            .map(\.key)
        for key in staleKeys {
            self.textLayoutCache.removeValue(forKey: key)
        }
    }

    func drawLineText(
        _ lineText: String,
        lineIndex: Int,
        font: Font,
        fallbackColor: Color,
        in context: inout UIGraphicsContext,
        at point: Point
    ) {
        let lineSpans =
            tokenSpans
            .filter { $0.line == lineIndex && $0.length > 0 }
            .sorted { lhs, rhs in
                if lhs.startColumn == rhs.startColumn {
                    lhs.length < rhs.length
                } else {
                    lhs.startColumn < rhs.startColumn
                }
            }

        guard !lineSpans.isEmpty else {
            drawString(lineText, font: font, color: fallbackColor, in: &context, at: point)
            return
        }

        let attributedText = self.attributedLineText(
            lineText,
            lineSpans: lineSpans,
            font: font,
            fallbackColor: fallbackColor,
            hoveredRange: sourceInteraction?.hoveredRange,
            lineIndex: lineIndex,
            hoverColor: environment.accentColor
        )
        self.drawAttributedString(attributedText, font: font, in: &context, at: point)
    }

    func attributedLineText(
        _ lineText: String,
        lineSpans: [TextEditorTokenSpan],
        font: Font,
        fallbackColor: Color,
        hoveredRange: TextEditorSourceRange? = nil,
        lineIndex: Int = 0,
        hoverColor: Color? = nil
    ) -> AttributedText {
        var fallbackAttributes = TextAttributeContainer()
        fallbackAttributes.font = font
        fallbackAttributes.foregroundColor = fallbackColor

        var attributedText = AttributedText(lineText, attributes: fallbackAttributes)
        guard !lineText.isEmpty else {
            return attributedText
        }

        for span in lineSpans {
            let start = max(0, min(span.startColumn, lineText.count))
            let end = max(start, min(span.startColumn + span.length, lineText.count))
            guard start < end else {
                continue
            }

            var spanAttributes = fallbackAttributes
            spanAttributes.foregroundColor = span.color
            spanAttributes.font = span.font ?? font
            let startIndex = lineText.index(lineText.startIndex, offsetBy: start)
            let endIndex = lineText.index(lineText.startIndex, offsetBy: end)
            attributedText.setAttributes(spanAttributes, at: startIndex..<endIndex)
        }

        if let hoveredRange,
            let hoverColor,
            lineIndex >= hoveredRange.start.line,
            lineIndex <= hoveredRange.end.line {
            let startColumn = lineIndex == hoveredRange.start.line ? hoveredRange.start.column : 0
            let endColumn = lineIndex == hoveredRange.end.line ? hoveredRange.end.column : lineText.count
            let start = max(0, min(startColumn, lineText.count))
            let end = max(start, min(endColumn, lineText.count))

            if start < end {
                var hoverAttributes = fallbackAttributes
                hoverAttributes.foregroundColor = hoverColor
                let startIndex = lineText.index(lineText.startIndex, offsetBy: start)
                let endIndex = lineText.index(lineText.startIndex, offsetBy: end)
                attributedText.setAttributes(hoverAttributes, at: startIndex..<endIndex)
            }
        }

        return attributedText
    }

    func drawBorder(in context: inout UIGraphicsContext, rect: Rect, color: Color) {
        let topLeft = Point(rect.minX, -rect.minY)
        let topRight = Point(rect.maxX, -rect.minY)
        let bottomLeft = Point(rect.minX, -rect.maxY)
        let bottomRight = Point(rect.maxX, -rect.maxY)

        context.drawLine(start: topLeft, end: topRight, lineWidth: 1, color: color)
        context.drawLine(start: topLeft, end: bottomLeft, lineWidth: 1, color: color)
        context.drawLine(start: topRight, end: bottomRight, lineWidth: 1, color: color)
        context.drawLine(start: bottomLeft, end: bottomRight, lineWidth: 1, color: color)
    }

    func textContentRect() -> Rect {
        Rect(
            x: Constants.horizontalInset,
            y: Constants.verticalInset,
            width: max(0, self.frame.width - Constants.horizontalInset * 2),
            height: max(0, self.frame.height - Constants.verticalInset * 2)
        )
    }

    func textRect() -> Rect {
        let content = self.textContentRect()
        return Rect(
            x: content.origin.x + self.gutterInset,
            y: content.origin.y,
            width: max(0, content.width - self.gutterInset),
            height: content.height
        )
    }

    var gutterInset: Float {
        self.showsLineNumbers ? Constants.gutterWidth + Constants.gutterSpacing : 0
    }

    func visualAbsoluteContentRect() -> Rect {
        let absoluteFrame = self.visualAbsoluteFrame()
        return Rect(
            x: absoluteFrame.origin.x + Constants.horizontalInset,
            y: absoluteFrame.origin.y + Constants.verticalInset,
            width: max(0, self.frame.width - Constants.horizontalInset * 2),
            height: max(0, self.frame.height - Constants.verticalInset * 2)
        )
    }

    func viewportChromeRect() -> Rect {
        guard let scrollView = self.nearestScrollView() else {
            return Rect(origin: .zero, size: self.frame.size)
        }

        return Rect(origin: scrollView.contentOffset, size: scrollView.frame.size)
    }

    func convertPointFromRoot(_ point: Point) -> Point {
        let visualFrame = self.visualAbsoluteFrame()
        return Point(x: point.x - visualFrame.minX, y: point.y - visualFrame.minY)
    }

    func requestDisplay() {
        self.invalidateNearestLayer()
        self.owner?.containerView?.setNeedsDisplay(in: self.visualAbsoluteFrame())
    }

    func activateTextCursorIfNeeded() {
        guard !self.isCursorActive else {
            return
        }

        self.isCursorActive = true
        self.owner?.window?.windowManager.setCursorShape(.iBeam)
    }

    func resetTextCursorIfNeeded() {
        guard self.isCursorActive else {
            return
        }

        self.isCursorActive = false
        self.owner?.window?.windowManager.setCursorShape(.arrow)
    }

    func activateSourceCursorIfNeeded() {
        guard !self.isSourceCursorActive else {
            return
        }

        self.isSourceCursorActive = true
        self.isCursorActive = false
        self.owner?.window?.windowManager.setCursorShape(.pointingHand)
    }

    func resetSourceCursorIfNeeded() {
        guard self.isSourceCursorActive else {
            return
        }

        self.isSourceCursorActive = false
        self.owner?.window?.windowManager.setCursorShape(.arrow)
    }

    func resetCaretBlink() {
        self.caretBlinkElapsed = 0
        if !self.caretVisible {
            self.caretVisible = true
            self.requestDisplay()
        }
    }

    func resolvedFontPointSize() -> Float {
        if let font = self.environment.font {
            return Float(font.pointSize)
        }
        return 14
    }

    func resolvedFontForRendering() -> Font? {
        if let font = self.environment.font {
            return font
        }

        if unsafe RenderEngine.shared != nil {
            return .system(size: 14)
        }

        return nil
    }

    func resolvedTextColor() -> Color {
        self.environment.foregroundColor ?? .black
    }

    func characterAdvance(for pointSize: Float) -> Float {
        max(6, pointSize * 0.58)
    }

    func caretXOffset(forColumn column: Int, in lineText: String, font: Font?, pointSize: Float) -> Float {
        let clamped = max(0, min(column, lineText.count))
        guard let caretStops = self.layoutCaretStops(for: lineText, font: font, pointSize: pointSize), !caretStops.isEmpty else {
            return Float(clamped) * self.characterAdvance(for: pointSize)
        }

        let scalarOffset = Self.scalarOffset(forCharacterOffset: clamped, in: lineText)
        let safeIndex = max(0, min(scalarOffset, caretStops.count - 1))
        return caretStops[safeIndex]
    }

    func closestColumn(toX x: Float, in lineText: String, font: Font?, pointSize: Float) -> Int {
        guard let caretStops = self.layoutCaretStops(for: lineText, font: font, pointSize: pointSize), !caretStops.isEmpty else {
            let advance = self.characterAdvance(for: pointSize)
            guard advance > 0 else {
                return 0
            }

            return max(0, min(Int((x / advance).rounded()), lineText.count))
        }

        if x <= 0 {
            return 0
        }

        for index in 0..<(caretStops.count - 1) {
            let middle = (caretStops[index] + caretStops[index + 1]) * 0.5
            if x < middle {
                return Self.characterOffset(forScalarOffset: index, in: lineText)
            }
        }

        return Self.characterOffset(forScalarOffset: caretStops.count - 1, in: lineText)
    }

    func lineHeight(for pointSize: Float) -> Float {
        max(18, pointSize * 1.45)
    }

    static func normalizeInputText(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func verticalTextOffset(for layout: TextLayoutManager, height: Float) -> Float {
        guard !layout.textLines.isEmpty else {
            return 0
        }

        var maxTopY: Float = -.infinity
        var minBottomY: Float = .infinity

        for line in layout.textLines {
            for run in line {
                for glyph in run {
                    maxTopY = max(maxTopY, glyph.position.w)
                    minBottomY = min(minBottomY, glyph.position.y)
                }
            }
        }

        guard maxTopY.isFinite, minBottomY.isFinite else {
            return 0
        }

        let textCenterY = (maxTopY + minBottomY) / 2
        let frameCenterY = -height / 2
        return frameCenterY - textCenterY
    }

    private func layoutCaretStops(for lineText: String, font: Font?, pointSize: Float) -> [Float]? {
        guard let font else {
            return nil
        }

        guard !lineText.isEmpty else {
            return [0]
        }

        var attributes = TextAttributeContainer()
        attributes.font = font
        attributes.foregroundColor = self.resolvedTextColor()
        let layout = self.cachedTextLayout(
            for: AttributedText(lineText, attributes: attributes),
            lineHeight: self.lineHeight(for: pointSize)
        )

        var stops: [Float] = [0]
        stops.reserveCapacity(lineText.unicodeScalars.count + 1)

        for line in layout.textLines {
            for run in line {
                for glyph in run {
                    stops.append(max(stops.last ?? 0, glyph.advanceX))
                }
            }
        }

        return stops.isEmpty ? [0] : stops
    }

    private static func scalarOffset(forCharacterOffset offset: Int, in text: String) -> Int {
        let clamped = max(0, min(offset, text.count))
        if clamped == 0 {
            return 0
        }

        let index = text.index(text.startIndex, offsetBy: clamped)
        return text[..<index].unicodeScalars.count
    }

    private static func characterOffset(forScalarOffset offset: Int, in text: String) -> Int {
        let clamped = max(0, min(offset, text.unicodeScalars.count))
        if clamped == 0 {
            return 0
        }

        var scalarCount = 0
        var characterCount = 0

        for character in text {
            let count = character.unicodeScalars.count
            if scalarCount + count > clamped {
                break
            }

            scalarCount += count
            characterCount += 1
            if scalarCount == clamped {
                break
            }
        }

        return characterCount
    }
}
