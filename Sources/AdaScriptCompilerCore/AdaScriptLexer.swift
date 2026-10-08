import Foundation

struct Lexer {
    private let source: String
    private var index: String.Index
    private var line = 1
    private var offset = 0

    init(source: String) {
        self.source = source
        self.index = source.startIndex
    }

    mutating func lex() -> [Token] {
        var tokens: [Token] = []
        while index < source.endIndex {
            if source[index].isWhitespace {
                advance()
            } else if hasPrefix("//") {
                while index < source.endIndex, source[index] != "\n" { advance() }
            } else if hasPrefix("/*") {
                advance(2)
                while index < source.endIndex, !hasPrefix("*/") { advance() }
                advance(2)
            } else if source[index] == "\"" {
                let startOffset = offset
                let tokenLine = line
                let result = lexString()
                tokens.append(Token(endOffset: result.endOffset, kind: .string, line: tokenLine, startOffset: startOffset, text: result.text))
            } else if source[index].isLetter || source[index] == "_" {
                let startOffset = offset
                let tokenLine = line
                let text = lexIdentifier()
                tokens.append(Token(endOffset: offset, kind: .identifier, line: tokenLine, startOffset: startOffset, text: text))
            } else if source[index].isNumber {
                let startOffset = offset
                let tokenLine = line
                let text = lexNumber()
                tokens.append(Token(endOffset: offset, kind: .number, line: tokenLine, startOffset: startOffset, text: text))
            } else {
                let startOffset = offset
                let tokenLine = line
                let character = source[index]
                advance()
                tokens.append(Token(endOffset: offset, kind: .punctuation, line: tokenLine, startOffset: startOffset, text: String(character)))
            }
        }
        return tokens
    }

    private mutating func lexString() -> (endOffset: Int, text: String) {
        advance()
        var result = ""
        while index < source.endIndex, source[index] != "\"" {
            if source[index] == "\\" {
                advance()
            }
            guard index < source.endIndex else {
                break
            }
            result.append(source[index])
            advance()
        }
        advance()
        return (offset, result)
    }

    private mutating func lexIdentifier() -> String {
        let start = index
        while index < source.endIndex, source[index].isLetter || source[index].isNumber || source[index] == "_" { advance() }
        return String(source[start..<index])
    }

    private mutating func lexNumber() -> String {
        let start = index
        while index < source.endIndex, source[index].isNumber || ".eE+-".contains(source[index]) { advance() }
        return String(source[start..<index])
    }

    private func hasPrefix(_ value: String) -> Bool { source[index...].hasPrefix(value) }

    private mutating func advance(_ distance: Int = 1) {
        for _ in 0..<distance where index < source.endIndex {
            if source[index] == "\n" {
                line += 1
            }
            index = source.index(after: index)
            offset += 1
        }
    }
}
