//
//  TextEditorFoldParser.swift
//  AdaEngine
//

import Foundation

enum TextEditorFoldParser {
    static func braceRanges(in lines: [String]) -> [Int: Range<Int>] {
        var ranges: [Int: Range<Int>] = [:]
        var openings: [Int] = []
        var inBlockComment = false

        for (lineIndex, line) in lines.enumerated() {
            let characters = Array(line)
            var quotedBy: Character?
            var escaped = false
            var column = 0
            while column < characters.count {
                let character = characters[column]
                let next = column + 1 < characters.count ? characters[column + 1] : nil
                if inBlockComment {
                    if character == "*", next == "/" {
                        inBlockComment = false
                        column += 2
                    } else {
                        column += 1
                    }
                    continue
                }
                if let quote = quotedBy {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == quote {
                        quotedBy = nil
                    }
                    column += 1
                    continue
                }
                if character == "/", next == "/" { break }
                if character == "/", next == "*" {
                    inBlockComment = true
                    column += 2
                    continue
                }
                if character == "\"" || character == "'" {
                    quotedBy = character
                } else if character == "{" {
                    openings.append(lineIndex)
                } else if character == "}", let opening = openings.popLast(), lineIndex > opening + 1 {
                    if lineIndex > (ranges[opening]?.upperBound ?? 0) {
                        ranges[opening] = (opening + 1)..<lineIndex
                    }
                }
                column += 1
            }
        }
        return ranges
    }

    static func indentationRanges(in lines: [String]) -> [Int: Range<Int>] {
        var ranges: [Int: Range<Int>] = [:]
        var open: [(line: Int, indentation: Int, hasBody: Bool)] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let indentation = self.indentationWidth(in: line)
            while let candidate = open.last, indentation <= candidate.indentation {
                open.removeLast()
                if candidate.hasBody {
                    ranges[candidate.line] = (candidate.line + 1)..<index
                }
            }
            if !open.isEmpty {
                open[open.count - 1].hasBody = true
            }
            if trimmed.hasSuffix(":") {
                open.append((index, indentation, false))
            }
        }
        for candidate in open where candidate.hasBody {
            ranges[candidate.line] = (candidate.line + 1)..<lines.count
        }
        return ranges
    }

    private static func indentationWidth(in text: String) -> Int {
        var width = 0
        for character in text {
            if character == " " {
                width += 1
            } else if character == "\t" {
                width += 4
            } else {
                break
            }
        }
        return width
    }
}
