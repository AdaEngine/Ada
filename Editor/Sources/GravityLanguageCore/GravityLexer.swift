import Foundation

struct GravityToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case comment
        case identifier
        case number
        case punctuation
        case string
    }

    var kind: Kind
    var text: String
    var range: GravitySourceRange
}

struct GravityLexResult: Sendable {
    var diagnostics: [GravityDiagnostic]
    var tokens: [GravityToken]
}

struct GravityLexer {
    private let source: String
    private var index: String.Index
    private var line = 0
    private var utf16Column = 0
    private var diagnostics: [GravityDiagnostic] = []
    private var tokens: [GravityToken] = []
    private var delimiters: [(Character, GravitySourcePosition)] = []

    init(source: String) {
        self.source = source
        self.index = source.startIndex
    }

    mutating func lex() -> GravityLexResult {
        while let character = currentCharacter {
            if character.isWhitespace {
                advance()
            } else if character == "/", peekCharacter() == "/" {
                lexLineComment()
            } else if character == "/", peekCharacter() == "*" {
                lexBlockComment()
            } else if character == "\"" || character == "'" {
                lexString(quote: character)
            } else if isIdentifierStart(character) {
                lexIdentifier()
            } else if character.isNumber {
                lexNumber()
            } else {
                lexPunctuation(character)
            }
        }

        for (delimiter, position) in delimiters.reversed() {
            diagnostics.append(
                GravityDiagnostic(
                    message: "Unclosed '\(delimiter)'",
                    range: GravitySourceRange(start: position, end: positionAfterCharacter(at: position, character: delimiter))
                )
            )
        }
        return GravityLexResult(diagnostics: diagnostics, tokens: tokens)
    }

    private var currentCharacter: Character? {
        index < source.endIndex ? source[index] : nil
    }

    private var position: GravitySourcePosition {
        GravitySourcePosition(line: line, utf16Column: utf16Column)
    }

    private func peekCharacter() -> Character? {
        guard index < source.endIndex else {
            return nil
        }
        let nextIndex = source.index(after: index)
        return nextIndex < source.endIndex ? source[nextIndex] : nil
    }

    private mutating func advance() {
        guard let character = currentCharacter else {
            return
        }
        index = source.index(after: index)
        if character == "\n" {
            line += 1
            utf16Column = 0
        } else {
            utf16Column += String(character).utf16.count
        }
    }

    private mutating func lexLineComment() {
        let startIndex = index
        let startPosition = position
        advance()
        advance()
        while let character = currentCharacter, character != "\n" {
            advance()
        }
        appendToken(kind: .comment, from: startIndex, position: startPosition)
    }

    private mutating func lexBlockComment() {
        let startIndex = index
        let startPosition = position
        var depth = 0
        while currentCharacter != nil {
            if currentCharacter == "/", peekCharacter() == "*" {
                depth += 1
                advance()
                advance()
            } else if currentCharacter == "*", peekCharacter() == "/" {
                depth -= 1
                advance()
                advance()
                if depth == 0 {
                    break
                }
            } else {
                advance()
            }
        }
        appendToken(kind: .comment, from: startIndex, position: startPosition)
        if depth != 0 {
            diagnostics.append(
                GravityDiagnostic(
                    message: "Unterminated block comment",
                    range: GravitySourceRange(start: startPosition, end: position)
                )
            )
        }
    }

    private mutating func lexString(quote: Character) {
        let startIndex = index
        let startPosition = position
        var escaped = false
        var terminated = false
        advance()
        while let character = currentCharacter {
            advance()
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == quote {
                terminated = true
                break
            }
        }
        appendToken(kind: .string, from: startIndex, position: startPosition)
        if !terminated {
            diagnostics.append(
                GravityDiagnostic(
                    message: "Unterminated string literal",
                    range: GravitySourceRange(start: startPosition, end: position)
                )
            )
        }
    }

    private mutating func lexIdentifier() {
        let startIndex = index
        let startPosition = position
        while let character = currentCharacter, isIdentifierContinuation(character) {
            advance()
        }
        appendToken(kind: .identifier, from: startIndex, position: startPosition)
    }

    private mutating func lexNumber() {
        let startIndex = index
        let startPosition = position
        while let character = currentCharacter, character.isNumber || character == "." || character == "_" {
            advance()
        }
        appendToken(kind: .number, from: startIndex, position: startPosition)
    }

    private mutating func lexPunctuation(_ character: Character) {
        let startIndex = index
        let startPosition = position
        advance()
        appendToken(kind: .punctuation, from: startIndex, position: startPosition)

        if "([{".contains(character) {
            delimiters.append((character, startPosition))
        } else if ")]}".contains(character) {
            let expectedOpening: Character =
                switch character {
                case ")": "("
                case "]": "["
                default: "{"
                }
            if delimiters.last?.0 == expectedOpening {
                delimiters.removeLast()
            } else {
                diagnostics.append(
                    GravityDiagnostic(
                        message: "Unexpected '\(character)'",
                        range: GravitySourceRange(start: startPosition, end: position)
                    )
                )
            }
        }
    }

    private mutating func appendToken(kind: GravityToken.Kind, from startIndex: String.Index, position startPosition: GravitySourcePosition) {
        tokens.append(
            GravityToken(
                kind: kind,
                text: String(source[startIndex..<index]),
                range: GravitySourceRange(start: startPosition, end: position)
            )
        )
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private func isIdentifierContinuation(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }

    private func positionAfterCharacter(at position: GravitySourcePosition, character: Character) -> GravitySourcePosition {
        GravitySourcePosition(line: position.line, utf16Column: position.utf16Column + String(character).utf16.count)
    }
}
