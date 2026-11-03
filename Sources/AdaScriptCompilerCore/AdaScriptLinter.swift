/// Stable identifiers shared by editor diagnostics and command-line checks.
public enum AdaScriptLintRule: String, CaseIterable, Sendable {
    case operatorSpacing = "operator_spacing"
    case commaSpacing = "comma_spacing"
    case colonSpacing = "colon_spacing"
    case controlKeywordSpacing = "control_keyword_spacing"
    case statementNewline = "statement_newline"
    case declarationSpacing = "declaration_spacing"

    /// English diagnostic text; clients can use it as a localization key.
    public var message: String {
        switch self {
        case .operatorSpacing: "Add spaces around binary operators."
        case .commaSpacing: "Put a space after commas and no space before them."
        case .colonSpacing: "Put a space after colons."
        case .controlKeywordSpacing: "Put a space between the control keyword and '('."
        case .statementNewline: "Put each statement on a separate line."
        case .declarationSpacing: "Separate type and function declarations with a blank line."
        }
    }
}

public struct AdaScriptLintIssue: Equatable, Sendable {
    public var rule: AdaScriptLintRule
    public var range: AdaScriptSourceRange

    public init(rule: AdaScriptLintRule, range: AdaScriptSourceRange) {
        self.rule = rule
        self.range = range
    }
}

/// Checks source layout without compiling or changing it. Comments and strings remain opaque,
/// and positions use the same zero-based lines and UTF-16 columns as compiler diagnostics.
public enum AdaScriptLinter {
    private static let controlKeywords: Set<String> = ["if", "while", "for", "switch", "catch"]
    private static let binaryOperators: Set<String> = [
        "=", "+", "-", "*", "/", "%", "==", "!=", "===", "!==", "<", ">", "<=", ">=", "&&", "||",
        "&", "|", "^", "<<", ">>", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "~=", "->", "?",
    ]

    public static func lint(source: String) -> [AdaScriptLintIssue] {
        var lexer = AdaScriptAnalysisLexer(source: source)
        let tokens = coalescingOperators(lexer.lex())
        var issues: [AdaScriptLintIssue] = []
        var braceDepth = 0
        var parenthesisBraceDepths: [Int] = []
        for index in tokens.indices {
            let token = tokens[index]
            let previous = index > 0 ? tokens[index - 1] : nil
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            if token.kind == .punctuation {
                switch token.text {
                case "(": parenthesisBraceDepths.append(braceDepth)
                case ")": _ = parenthesisBraceDepths.popLast()
                case "{": braceDepth += 1
                case "}": braceDepth = max(0, braceDepth - 1)
                case ";":
                    let followingStatement = tokens.dropFirst(index + 1).first { $0.kind != .comment }
                    let insideBody = parenthesisBraceDepths.last.map { $0 < braceDepth } ?? true
                    if insideBody, let followingStatement,
                        followingStatement.text != "}", followingStatement.range.start.line == token.range.end.line {
                        issues.append(.init(rule: .statementNewline, range: followingStatement.range))
                    }
                case ",":
                    let trailing = next.map { [")", "]", "}"].contains($0.text) } ?? false
                    if (!trailing && missingSpace(after: token, before: next)) || hasSpace(after: previous, before: token) {
                        issues.append(.init(rule: .commaSpacing, range: token.range))
                    }
                case ":":
                    if missingSpace(after: token, before: next) {
                        issues.append(.init(rule: .colonSpacing, range: token.range))
                    }
                default:
                    let operand = previous?.kind == .comment ? tokens.prefix(index).last { $0.kind != .comment } : previous
                    if binaryOperators.contains(token.text),
                        !isNumericRangeEnd(token, after: previous),
                        !isUnary(token, after: operand), previous != nil, next != nil,
                        missingSpace(after: previous, before: token) || missingSpace(after: token, before: next) {
                        issues.append(.init(rule: .operatorSpacing, range: token.range))
                    }
                }
            } else if token.kind == .identifier, controlKeywords.contains(token.text), next?.text == "(",
                missingSpace(after: token, before: next) {
                issues.append(.init(rule: .controlKeywordSpacing, range: token.range))
            }
        }
        issues += declarationIssues(source: source)
        return issues.sorted {
            if $0.range.start.line != $1.range.start.line {
                return $0.range.start.line < $1.range.start.line
            }
            if $0.range.start.utf16Column != $1.range.start.utf16Column {
                return $0.range.start.utf16Column < $1.range.start.utf16Column
            }
            return $0.rule.rawValue < $1.rule.rawValue
        }
    }

    private static func missingSpace(after left: AdaScriptAnalysisToken?, before right: AdaScriptAnalysisToken?) -> Bool {
        guard let left, let right else {
            return false
        }
        return left.endOffset == right.startOffset
    }

    private static func hasSpace(after left: AdaScriptAnalysisToken?, before right: AdaScriptAnalysisToken) -> Bool {
        guard let left, left.kind != .comment else {
            return false
        }
        return left.range.end.line == right.range.start.line && left.endOffset < right.startOffset
    }

    private static func isUnary(_ token: AdaScriptAnalysisToken, after previous: AdaScriptAnalysisToken?) -> Bool {
        guard token.text == "+" || token.text == "-" else {
            return false
        }
        guard let previous else {
            return true
        }
        if previous.kind == .number || previous.kind == .string {
            return false
        }
        if previous.kind == .identifier {
            return ["return", "throw", "yield", "in", "case"].contains(previous.text)
        }
        return !["}", "]", ")"].contains(previous.text)
    }

    private static func isNumericRangeEnd(_ token: AdaScriptAnalysisToken, after previous: AdaScriptAnalysisToken?) -> Bool {
        // The shared number lexer includes adjacent dots in `0..<count` in the number token.
        token.text == "<" && previous?.kind == .number && previous?.text.hasSuffix("..") == true
    }

    /// The analysis lexer exposes punctuation one character at a time. Use the language's longest
    /// operator so `a >= b`, `value += -1` and return type arrows are checked as single units.
    private static func coalescingOperators(_ tokens: [AdaScriptAnalysisToken]) -> [AdaScriptAnalysisToken] {
        var result: [AdaScriptAnalysisToken] = []
        var index = 0
        while index < tokens.count {
            var token = tokens[index]
            var end = index + 1
            if token.kind == .punctuation {
                var candidate = token.text
                var cursor = end
                while cursor < min(index + 3, tokens.count), tokens[cursor].kind == .punctuation,
                    tokens[cursor - 1].endOffset == tokens[cursor].startOffset {
                    candidate += tokens[cursor].text
                    if binaryOperators.contains(candidate) || candidate == "..." || candidate == "..<" {
                        token.text = candidate
                        token.endOffset = tokens[cursor].endOffset
                        token.range.end = tokens[cursor].range.end
                        end = cursor + 1
                    }
                    cursor += 1
                }
            }
            result.append(token)
            index = end
        }
        return result
    }

    private static func declarationIssues(source: String) -> [AdaScriptLintIssue] {
        let parsed = AdaScriptSyntaxParser(source: source, path: "").parse()
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
        var topLevel = parsed.types.map { declarationRange($0.syntax.range, annotations: $0.syntax.annotations) }
        topLevel += parsed.functions.map { declarationRange($0.syntax.range, annotations: $0.syntax.annotations) }
        let groups: [[AdaScriptSourceRange]] = [topLevel] + parsed.types.map { type in
            type.functions.map { declarationRange($0.syntax.range, annotations: $0.syntax.annotations) }
        }
        var issues: [AdaScriptLintIssue] = []
        for group in groups {
            let sorted = group.sorted { left, right in
                if left.start.line != right.start.line {
                    return left.start.line < right.start.line
                }
                return left.start.utf16Column < right.start.utf16Column
            }
            for (previous, next) in zip(sorted, sorted.dropFirst()) {
                let first = previous.end.line + 1
                let last = next.start.line
                if first < last, lines.indices.contains(first), lines.indices.contains(last),
                    lines[first..<last].contains(where: { $0.allSatisfy(\.isWhitespace) }) {
                    continue
                }
                let end = AdaScriptSourcePosition(line: next.start.line, utf16Column: next.start.utf16Column + 1)
                issues.append(.init(rule: .declarationSpacing, range: AdaScriptSourceRange(start: next.start, end: end)))
            }
        }
        return issues
    }

    private static func declarationRange(_ range: AdaScriptSourceRange, annotations: [AdaScriptAnnotationSyntax]) -> AdaScriptSourceRange {
        AdaScriptSourceRange(start: annotations.first?.range.start ?? range.start, end: range.end)
    }
}
