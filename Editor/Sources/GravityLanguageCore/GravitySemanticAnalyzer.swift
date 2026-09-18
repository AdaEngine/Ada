import Foundation

enum GravitySemanticAnalyzer {
    static func tokens(in text: String) -> [GravitySemanticToken] {
        var lexer = GravityLexer(source: text)
        let lexedTokens = lexer.lex().tokens
        let parsed = GravityDocumentAnalyzer.parse(text)

        return lexedTokens.enumerated()
            .flatMap { index, token -> [GravitySemanticToken] in
                guard
                    let kind = semanticKind(
                        at: index,
                        token: token,
                        tokens: lexedTokens,
                        typeRegions: parsed.typeRegions
                    )
                else {
                    return []
                }
                return semanticTokens(for: token, kind: kind)
            }
    }

    private static func semanticTokens(for token: GravityToken, kind: GravitySemanticTokenKind) -> [GravitySemanticToken] {
        let lines = token.text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else {
            return [GravitySemanticToken(kind: kind, range: token.range)]
        }
        return lines.enumerated()
            .compactMap { offset, line in
                let length = line.utf16.count
                guard length > 0 else {
                    return nil
                }
                let lineNumber = token.range.start.line + offset
                let startColumn = offset == 0 ? token.range.start.utf16Column : 0
                let start = GravitySourcePosition(line: lineNumber, utf16Column: startColumn)
                let end = GravitySourcePosition(line: lineNumber, utf16Column: startColumn + length)
                return GravitySemanticToken(kind: kind, range: GravitySourceRange(start: start, end: end))
            }
    }

    private static func semanticKind(
        at index: Int,
        token: GravityToken,
        tokens: [GravityToken],
        typeRegions: [GravityTypeRegion]
    ) -> GravitySemanticTokenKind? {
        switch token.kind {
        case .comment:
            return .comment
        case .number:
            return .number
        case .string:
            return .string
        case .punctuation:
            return token.text == "@" && nextSignificantToken(after: index, in: tokens)?.kind == .identifier ? .macro : nil
        case .identifier:
            return identifierKind(at: index, token: token, tokens: tokens, typeRegions: typeRegions)
        }
    }

    private static func identifierKind(
        at index: Int,
        token: GravityToken,
        tokens: [GravityToken],
        typeRegions: [GravityTypeRegion]
    ) -> GravitySemanticTokenKind? {
        let previous = previousSignificantToken(before: index, in: tokens)
        let next = nextSignificantToken(after: index, in: tokens)
        if previous?.text == "@" {
            return .macro
        }
        if keywords.contains(token.text) {
            return .keyword
        }
        if let declarationKind = declarationKind(previous: previous, token: token, typeRegions: typeRegions) {
            return declarationKind
        }
        if previous?.text == "." {
            return next?.text == "(" ? .method : .property
        }
        if next?.text == "(" {
            return .function
        }
        if token.text.first?.isUppercase == true {
            return .type
        }
        return nil
    }

    private static func declarationKind(
        previous: GravityToken?,
        token: GravityToken,
        typeRegions: [GravityTypeRegion]
    ) -> GravitySemanticTokenKind? {
        switch previous?.text {
        case "class":
            .class
        case "enum":
            .enum
        case "struct":
            .type
        case "func":
            typeRegions.contains(where: { $0.symbol.range.contains(token.range.start) }) ? .method : .function
        case "var",
            "const":
            typeRegions.contains(where: { $0.symbol.range.contains(token.range.start) }) ? .property : .variable
        default:
            nil
        }
    }

    private static func previousSignificantToken(before index: Int, in tokens: [GravityToken]) -> GravityToken? {
        guard index > 0 else {
            return nil
        }
        return tokens[..<index].last { $0.kind != .comment }
    }

    private static func nextSignificantToken(after index: Int, in tokens: [GravityToken]) -> GravityToken? {
        guard index + 1 < tokens.count else {
            return nil
        }
        return tokens[(index + 1)...].first { $0.kind != .comment }
    }

    private static let keywords: Set<String> = [
        "break", "case", "class", "const", "continue", "else", "enum", "event", "extern", "false", "for", "func", "if", "import", "in", "null",
        "private", "public", "repeat", "return", "static", "struct", "switch", "true", "var", "while",
    ]
}
