//
//  TextEditorViewNode+Folding.swift
//  AdaEngine
//

import Foundation
import Math

extension TextEditorViewNode {
    func foldRanges() -> [Int: Range<Int>] {
        if let foldRangesCache {
            return foldRangesCache
        }

        let lines = self.lines()
        let ranges: [Int: Range<Int>]
        switch self.foldingStyle {
        case .none:
            ranges = [:]
        case .braces:
            ranges = TextEditorFoldParser.braceRanges(in: lines.map(\.text))
        case .indentation:
            ranges = TextEditorFoldParser.indentationRanges(in: lines.map(\.text))
        }
        self.foldRangesCache = ranges
        return ranges
    }

    func displayedLines() -> [Int] {
        if let displayedLinesCache {
            return displayedLinesCache
        }

        let ranges = self.foldRanges()
        let count = self.lines().count
        var result: [Int] = []
        result.reserveCapacity(count)
        var line = 0
        while line < count {
            result.append(line)
            if self.collapsedFoldLines.contains(line), let hidden = ranges[line] {
                line = hidden.upperBound
            } else {
                line += 1
            }
        }
        self.displayedLinesCache = result
        return result
    }

    func displayRow(forLine line: Int) -> Int {
        let displayed = self.displayedLines()
        var lower = 0
        var upper = displayed.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if displayed[middle] <= line {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return max(0, lower - 1)
    }

    func sourceLine(atDisplayRow row: Int) -> Int {
        let displayed = self.displayedLines()
        return displayed[max(0, min(row, displayed.count - 1))]
    }

    func foldLine(at point: Point) -> Int? {
        guard self.foldingStyle != .none else {
            return nil
        }
        let gutter = self.gutterViewportRect()
        let left = gutter.minX + 14
        guard point.x >= left, point.x < left + 20, point.y >= self.textContentRect().minY else {
            return nil
        }
        let row = Int((point.y - self.textContentRect().minY) / self.lineHeight(for: self.resolvedFontPointSize()))
        guard row >= 0, row < self.displayedLines().count else {
            return nil
        }
        let line = self.sourceLine(atDisplayRow: row)
        return self.foldRanges()[line] == nil ? nil : line
    }

    func toggleFold(at line: Int) {
        guard let hidden = self.foldRanges()[line] else {
            return
        }
        if self.collapsedFoldLines.contains(line) {
            self.collapsedFoldLines.remove(line)
        } else {
            self.collapsedFoldLines.insert(line)
            let lines = self.lines()
            let anchorLine = self.position(forOffset: self.selectionAnchor, lines: lines).line
            let headLine = self.position(forOffset: self.selectionHead, lines: lines).line
            if hidden.contains(anchorLine) || hidden.contains(headLine) {
                let offset = lines[line].startOffset + lines[line].text.count
                self.setSelection(to: offset)
                self.notifyCaretChange(requestsCompletion: false)
            }
        }
        self.displayedLinesCache = nil
        self.markNeedsLayout()
        self.requestDisplay()
    }

    func revealCaretLineIfNeeded() {
        let line = self.position(forOffset: self.selectionHead, lines: self.lines()).line
        let ranges = self.foldRanges()
        let hiddenBy = self.collapsedFoldLines.filter { ranges[$0]?.contains(line) == true }
        guard !hiddenBy.isEmpty else {
            return
        }
        self.collapsedFoldLines.subtract(hiddenBy)
        self.displayedLinesCache = nil
        self.markNeedsLayout()
        self.requestDisplay()
    }


}
