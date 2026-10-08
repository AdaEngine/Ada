//
//  TextEditorViewNode+SelectionOccurrences.swift
//  AdaEngine
//

import AdaText
import AdaUtils
import Math

extension TextEditorViewNode {
    func selectionOccurrences() -> [Int: [Range<Int>]] {
        guard self.highlightsSelectedIdentifier, self.isFocused, self.hasSelection else { return [:] }
        let selection = self.selectionRange
        if self.cachedOccurrenceSelectionRange == selection {
            return self.cachedOccurrencesByLine
        }
        let previousWord = self.cachedOccurrenceWord
        let previousMatches = self.cachedOccurrencesByLine
        self.cachedOccurrenceSelectionRange = selection
        self.cachedOccurrenceWord = nil
        self.cachedOccurrencesByLine = [:]
        guard selection.count <= TextEditorIdentifierOccurrences.maximumIdentifierLength else { return [:] }

        let lines = self.lines()
        let start = self.position(forOffset: selection.lowerBound, lines: lines)
        let end = self.position(forOffset: selection.upperBound, lines: lines)
        guard start.line == end.line else { return [:] }
        let characters = Array(lines[start.line].text)
        guard start.column >= 0, end.column <= characters.count,
            (start.column == 0 || !TextEditorIdentifierOccurrences.isIdentifierCharacter(characters[start.column - 1])),
            (end.column == characters.count || !TextEditorIdentifierOccurrences.isIdentifierCharacter(characters[end.column]))
        else {
            return [:]
        }

        let word = self.selectedText()
        guard TextEditorIdentifierOccurrences.isIdentifier(word) else { return [:] }
        if previousWord == word {
            self.cachedOccurrenceWord = word
            self.cachedOccurrencesByLine = previousMatches
            return previousMatches
        }

        var matches: [Int: [Range<Int>]] = [:]
        for (lineIndex, line) in lines.enumerated() {
            let ranges = TextEditorIdentifierOccurrences.ranges(of: word, in: line.text)
            if !ranges.isEmpty {
                matches[lineIndex] = ranges
            }
        }
        self.cachedOccurrenceWord = word
        self.cachedOccurrencesByLine = matches
        return matches
    }

    func drawSelectionOccurrences(
        _ ranges: [Range<Int>],
        in context: inout UIGraphicsContext,
        line: LineInfo,
        rowY: Float,
        lineHeight: Float,
        pointSize: Float,
        font: Font?
    ) {
        let color = self.environment.accentColor
        for columns in ranges {
            let absoluteRange = (line.startOffset + columns.lowerBound)..<(line.startOffset + columns.upperBound)
            guard absoluteRange != self.selectionRange else { continue }
            let left = self.textRect().minX + self.caretXOffset(forColumn: columns.lowerBound, in: line.text, font: font, pointSize: pointSize)
            let right = self.textRect().minX + self.caretXOffset(forColumn: columns.upperBound, in: line.text, font: font, pointSize: pointSize)
            let frame = Rect(x: left - 1, y: rowY + 1, width: max(2, right - left + 2), height: max(1, lineHeight - 2))
            context.drawRect(frame, color: color.opacity(0.13))
            context.stroke(
                RoundedRectangleShape(cornerRadius: 2).path(in: frame),
                with: color.opacity(0.6),
                style: StrokeStyle(lineWidth: 1)
            )
        }
    }
}
