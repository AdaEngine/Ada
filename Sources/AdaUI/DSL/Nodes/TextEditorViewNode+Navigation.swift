//
//  TextEditorViewNode+Navigation.swift
//  AdaEngine
//
//  Created by Codex on 18.05.2026.
//

import AdaUtils
import Foundation
import Math

extension TextEditorViewNode {
    func lines() -> [LineInfo] {
        if let lineCache {
            return lineCache
        }

        var result: [LineInfo] = []
        var current = ""
        var startOffset = 0
        var offset = 0

        for character in self.text {
            if character == "\n" {
                result.append(LineInfo(text: current, startOffset: startOffset))
                current = ""
                offset += 1
                startOffset = offset
            } else {
                current.append(character)
                offset += 1
            }
        }

        result.append(LineInfo(text: current, startOffset: startOffset))
        self.lineCache = result
        return result
    }

    func invalidateTextCaches() {
        self.lineCache = nil
        self.textLayoutCache.removeAll(keepingCapacity: true)
    }

    func position(forOffset offset: Int, lines: [LineInfo]) -> TextPosition {
        let clamped = max(0, min(offset, self.text.count))
        var bestLine = 0

        for index in lines.indices {
            let line = lines[index]
            let lineEndOffset = line.startOffset + line.text.count
            if clamped <= lineEndOffset {
                return TextPosition(line: index, column: clamped - line.startOffset)
            }
            bestLine = index
        }

        let fallback = lines[bestLine]
        return TextPosition(line: bestLine, column: fallback.text.count)
    }

    func offset(line: Int, column: Int, lines: [LineInfo]) -> Int {
        guard !lines.isEmpty else {
            return 0
        }

        let lineIndex = max(0, min(line, lines.count - 1))
        return lines[lineIndex].startOffset + max(0, min(column, lines[lineIndex].text.count))
    }

    func closestOffset(to point: Point) -> Int {
        let lines = self.lines()
        let textRect = self.textRect()
        let pointSize = self.resolvedFontPointSize()
        let lineHeight = self.lineHeight(for: pointSize)
        let font = self.resolvedFontForRendering()

        let y = max(0, point.y - textRect.origin.y)
        let x = max(0, point.x - textRect.origin.x)
        let line = max(0, min(Int(y / max(1, lineHeight)), lines.count - 1))
        let column = self.closestColumn(toX: x, in: lines[line].text, font: font, pointSize: pointSize)
        return self.offset(line: line, column: column, lines: lines)
    }

    func sourcePosition(at point: Point) -> TextEditorSourcePosition {
        let lines = self.lines()
        let offset = self.closestOffset(to: point)
        let position = self.position(forOffset: offset, lines: lines)
        return TextEditorSourcePosition(line: position.line, column: position.column)
    }

    func offset(for sourcePosition: TextEditorSourcePosition) -> Int {
        self.offset(line: sourcePosition.line, column: sourcePosition.column, lines: self.lines())
    }

    func rangeOffsets(for sourceRange: TextEditorSourceRange) -> Range<Int> {
        let start = self.offset(for: sourceRange.start)
        let end = self.offset(for: sourceRange.end)
        return min(start, end)..<max(start, end)
    }

    func wordBoundaryBefore(offset: Int) -> Int {
        let characters = Array(self.text)
        var index = max(0, min(offset, characters.count))
        guard index > 0 else {
            return 0
        }

        while index > 0, !Self.isWordCharacter(characters[index - 1]) {
            index -= 1
        }

        while index > 0, Self.isWordCharacter(characters[index - 1]) {
            index -= 1
        }

        return index
    }

    func wordBoundaryAfter(offset: Int) -> Int {
        let characters = Array(self.text)
        let count = characters.count
        var index = max(0, min(offset, count))
        guard index < count else {
            return count
        }

        while index < count, !Self.isWordCharacter(characters[index]) {
            index += 1
        }

        while index < count, Self.isWordCharacter(characters[index]) {
            index += 1
        }

        return index
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        var hasScalars = false
        for scalar in character.unicodeScalars {
            hasScalars = true
            if scalar == "_" {
                continue
            }

            if !CharacterSet.alphanumerics.contains(scalar) {
                return false
            }
        }

        return hasScalars
    }

    func ensureCaretVisibleIfNeeded() {
        let lines = self.lines()
        let position = self.position(forOffset: self.caretOffset, lines: lines)
        let pointSize = self.resolvedFontPointSize()
        let lineHeight = self.lineHeight(for: pointSize)
        let characterAdvance = self.characterAdvance(for: pointSize)
        let font = self.resolvedFontForRendering()
        let textRect = self.textRect()
        let lineText = lines.indices.contains(position.line) ? lines[position.line].text : ""
        let caretRect = Rect(
            x: textRect.minX + self.caretXOffset(forColumn: position.column, in: lineText, font: font, pointSize: pointSize),
            y: textRect.minY + Float(position.line) * lineHeight,
            width: characterAdvance,
            height: lineHeight
        )
        let padding = EdgeInsets(
            top: Constants.caretScrollPadding,
            leading: Constants.caretScrollPadding,
            bottom: Constants.caretScrollPadding,
            trailing: Constants.caretScrollPadding
        )

        _ = self.nearestScrollView()?.scrollToVisibleRect(caretRect, in: self, padding: padding)
    }

    func visibleLineRange(lineHeight: Float, viewportHeight: Float) -> Range<Int> {
        let lines = self.lines()
        let scrollY = self.nearestScrollView()?.contentOffset.y ?? 0
        let firstLine = max(0, Int(max(0, scrollY - self.textContentRect().minY) / max(1, lineHeight)))
        let visibleCount = max(1, Int(ceil(viewportHeight / max(1, lineHeight))) + 2)
        let lowerBound = min(lines.count, firstLine)
        return lowerBound..<min(lines.count, lowerBound + visibleCount)
    }

    func isTap(at position: Point, start: Point?) -> Bool {
        guard let start else {
            return false
        }

        let dx = position.x - start.x
        let dy = position.y - start.y
        return dx * dx + dy * dy <= Constants.tapMovementToleranceSquared
    }

    func handleTapCompletion(at position: Point, time: AdaUtils.TimeInterval, caretOffset: Int) {
        if self.isDoubleTap(at: position, time: time) {
            self.selectWord(at: caretOffset)
            self.clearTapCandidate()
        } else {
            self.storeTapCandidate(at: position, time: time)
        }
    }

    func isDoubleTap(at position: Point, time: AdaUtils.TimeInterval) -> Bool {
        guard let lastTapTime, let lastTapPosition else {
            return false
        }

        let deltaTime = time - lastTapTime
        guard deltaTime >= 0, deltaTime <= Constants.doubleTapMaxInterval else {
            return false
        }

        let dx = position.x - lastTapPosition.x
        let dy = position.y - lastTapPosition.y
        return dx * dx + dy * dy <= Constants.doubleTapMovementToleranceSquared
    }

    func storeTapCandidate(at position: Point, time: AdaUtils.TimeInterval) {
        self.lastTapPosition = position
        self.lastTapTime = time
    }

    func clearTapCandidate() {
        self.lastTapPosition = nil
        self.lastTapTime = nil
    }

    func selectWord(at offset: Int) {
        let range = self.wordRange(at: offset)
        if range.isEmpty {
            self.setSelection(to: offset)
        } else {
            self.selectionAnchor = range.lowerBound
            self.selectionHead = range.upperBound
        }
        self.ensureCaretVisibleIfNeeded()
        self.requestDisplay()
    }

    func wordRange(at offset: Int) -> Range<Int> {
        let characters = Array(self.text)
        let count = characters.count
        guard count > 0 else {
            let clamped = max(0, min(offset, count))
            return clamped..<clamped
        }

        let clamped = max(0, min(offset, count))
        var index = clamped
        if index == count {
            index = count - 1
        }

        if !Self.isWordCharacter(characters[index]) {
            if index > 0, Self.isWordCharacter(characters[index - 1]) {
                index -= 1
            } else {
                return clamped..<clamped
            }
        }

        var start = index
        var end = index + 1
        while start > 0, Self.isWordCharacter(characters[start - 1]) {
            start -= 1
        }

        while end < count, Self.isWordCharacter(characters[end]) {
            end += 1
        }

        return start..<end
    }

    func nearestScrollView() -> ScrollViewNode? {
        var current = self.parent
        while let node = current {
            if let scrollView = node as? ScrollViewNode {
                return scrollView
            }
            current = node.parent
        }

        return nil
    }
}
