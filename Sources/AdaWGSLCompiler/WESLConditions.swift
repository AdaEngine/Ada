#if !os(WASI)
import Foundation

struct WESLConditions {
    let tokens: [String]
    let features: [String: Bool]
    let file: URL

    func expand() throws -> [String] {
        try expand(tokens.indices)
    }

    private func expand(_ range: Range<Int>, depth: Int = 0) throws -> [String] {
        guard depth < 128 else { throw failure("WESL conditional nesting limit exceeded") }
        var result: [String] = []
        var cursor = range.lowerBound
        var previousMatch: Bool?
        while cursor < range.upperBound {
            guard tokens[cursor] == "@",
                  let branch = try conditionalAttributes(at: cursor, limit: range.upperBound) else {
                result.append(tokens[cursor])
                cursor += 1
                previousMatch = nil
                continue
            }
            let selected: Bool
            switch branch.kind {
            case "if":
                selected = branch.enabled
                previousMatch = selected
            case "elif":
                guard let previousMatch else { throw failure("Unexpected @elif without @if") }
                selected = !previousMatch && branch.enabled
            default:
                guard let previousMatch else { throw failure("Unexpected @else without @if") }
                selected = !previousMatch
            }
            let end = try nodeEnd(from: branch.body, limit: range.upperBound)
            if selected {
                result += branch.attributes
                result += try expand(branch.body..<end, depth: depth + 1)
            }
            if branch.kind == "elif" { previousMatch = (previousMatch ?? false) || selected }
            if branch.kind == "else" { previousMatch = nil }
            cursor = end
        }
        return result
    }

    private func conditionalAttributes(at start: Int, limit: Int) throws -> Branch? {
        var cursor = start
        var ordinary: [String] = []
        var condition: (kind: String, enabled: Bool)?
        while cursor + 1 < limit, tokens[cursor] == "@" {
            let attributeStart = cursor
            let name = tokens[cursor + 1]
            cursor += 2
            var argument: Range<Int>?
            if cursor < limit, tokens[cursor] == "(" {
                let end = try closingParen(from: cursor, limit: limit)
                argument = (cursor + 1)..<end
                cursor = end + 1
            }
            if ["if", "elif", "else"].contains(name) {
                guard condition == nil else { throw failure("Multiple conditions on one WESL declaration") }
                if name == "else" {
                    guard argument == nil else { throw failure("@else takes no expression") }
                    condition = (name, true)
                } else {
                    guard let argument else { throw failure("@\(name) requires a feature expression") }
                    var evaluator = Evaluator(tokens: tokens[argument], features: features)
                    do { condition = (name, try evaluator.evaluate()) }
                    catch { throw failure("Invalid @\(name) feature expression") }
                }
            } else {
                ordinary += tokens[attributeStart..<cursor]
            }
        }
        guard let condition else { return nil }
        return Branch(kind: condition.kind, enabled: condition.enabled, attributes: ordinary, body: cursor)
    }

    private func nodeEnd(from start: Int, limit: Int) throws -> Int {
        guard start < limit else { throw failure("Missing conditional WESL declaration") }
        var stack: [String] = []
        var readingType = false
        let isImport = tokens[start] == "import"
        let isAlias = tokens[start] == "alias"
        var index = start
        while index < limit {
            let token = tokens[index]
            switch token {
            case ":":
                if stack.isEmpty { readingType = true }
            case "=":
                if stack.isEmpty { readingType = isAlias }
            case "<":
                if readingType || (index > start && tokens[index - 1] == "var") { stack.append(">") }
            case ">":
                if stack.last == ">" { stack.removeLast() }
            case ">>":
                if stack.last == ">" { stack.removeLast() }
                if stack.last == ">" { stack.removeLast() }
            case "(": stack.append(")")
            case "[": stack.append("]")
            case "{": stack.append("}")
            case ")", "]", "}":
                if stack.isEmpty { return index }
                guard stack.popLast() == token else { throw failure("Unbalanced delimiters in WESL declaration") }
                if token == "}", stack.isEmpty, !isImport,
                   index + 1 == limit || tokens[index + 1] != "else" {
                    return index + 1
                }
            case ";", ",":
                if stack.isEmpty { return index + 1 }
            default: break
            }
            index += 1
        }
        guard stack.isEmpty else { throw failure("Unterminated conditional WESL declaration") }
        return limit
    }

    private func closingParen(from start: Int, limit: Int) throws -> Int {
        var depth = 0
        for index in start..<limit {
            if tokens[index] == "(" { depth += 1 }
            if tokens[index] == ")" { depth -= 1 }
            if depth == 0 { return index }
        }
        throw failure("Unterminated WESL attribute")
    }

    private func failure(_ message: String) -> WESLLinker.Failure {
        .init("\(message) in \(file.path)")
    }

    private struct Branch {
        let kind: String
        let enabled: Bool
        let attributes: [String]
        let body: Int
    }

    private struct Evaluator {
        var tokens: ArraySlice<String>
        let features: [String: Bool]

        mutating func evaluate() throws -> Bool {
            let value = try disjunction(depth: 0)
            guard tokens.isEmpty else { throw InvalidExpression() }
            return value
        }

        private mutating func disjunction(depth: Int) throws -> Bool {
            var value = try conjunction(depth: depth)
            while consume("||") {
                let right = try conjunction(depth: depth)
                value = value || right
            }
            return value
        }

        private mutating func conjunction(depth: Int) throws -> Bool {
            var value = try unary(depth: depth)
            while consume("&&") {
                let right = try unary(depth: depth)
                value = value && right
            }
            return value
        }

        private mutating func unary(depth: Int) throws -> Bool {
            guard depth < 128 else { throw InvalidExpression() }
            if consume("!") { return try !unary(depth: depth + 1) }
            if consume("(") {
                let value = try disjunction(depth: depth + 1)
                guard consume(")") else { throw InvalidExpression() }
                return value
            }
            guard let token = tokens.popFirst(), let first = token.first,
                  first == "_" || first.isLetter else { throw InvalidExpression() }
            if token == "true" { return true }
            if token == "false" { return false }
            return features[token, default: false]
        }

        private mutating func consume(_ value: String) -> Bool {
            guard tokens.first == value else { return false }
            tokens.removeFirst()
            return true
        }

        private struct InvalidExpression: Error {}
    }
}
#endif
