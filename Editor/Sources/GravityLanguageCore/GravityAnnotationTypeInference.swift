import Foundation

extension GravityDocumentAnalyzer {
    static func annotationNames(before declarationIndex: Int, in tokens: [GravityToken]) -> Set<String> {
        Set(annotationTokens(before: declarationIndex, in: tokens).map(\.text))
    }

    static func annotationTokens(before declarationIndex: Int, in tokens: [GravityToken]) -> [GravityToken] {
        guard declarationIndex > 0 else {
            return []
        }
        var annotations: [GravityToken] = []
        var cursor = declarationIndex - 1
        var parenthesisDepth = 0
        while cursor >= 0 {
            let token = tokens[cursor]
            if token.text == ")" {
                parenthesisDepth += 1
            } else if token.text == "(" {
                parenthesisDepth = max(0, parenthesisDepth - 1)
            } else if parenthesisDepth == 0,
                token.kind == .identifier,
                cursor > 0,
                tokens[cursor - 1].text == "@" {
                annotations.append(token)
                cursor -= 1
            } else if parenthesisDepth == 0,
                token.text == ";" || token.text == "}" || typeKeywordNames.contains(token.text) {
                break
            }
            cursor -= 1
        }
        return annotations.reversed()
    }

    static func implicitTypes(
        annotations: Set<String>,
        openBraceIndex: Int,
        closeBraceIndex: Int,
        tokens: [GravityToken]
    ) -> [String: String] {
        let lifecycleTypes = lifecycleTypes(for: annotations)
        guard !lifecycleTypes.isEmpty else {
            return [:]
        }

        var result: [String: String] = [:]
        var braceDepth = 0
        var index = openBraceIndex + 1
        while index < closeBraceIndex, index < tokens.count {
            let token = tokens[index]
            if token.text == "{" {
                braceDepth += 1
            } else if token.text == "}" {
                braceDepth = max(0, braceDepth - 1)
            } else if braceDepth == 0,
                token.text == "func",
                let binding = lifecycleBinding(at: index, upperBound: closeBraceIndex, tokens: tokens, lifecycleTypes: lifecycleTypes) {
                result[binding.name] = binding.type
            }
            index += 1
        }
        return result
    }

    private static func lifecycleBinding(
        at functionIndex: Int,
        upperBound: Int,
        tokens: [GravityToken],
        lifecycleTypes: [String: String]
    ) -> (name: String, type: String)? {
        guard
            let methodIndex = nextLifecycleIdentifier(after: functionIndex, upperBound: upperBound, tokens: tokens),
            let parameterType = lifecycleTypes[tokens[methodIndex].text],
            let openParenthesisIndex = nextLifecycleToken("(", after: methodIndex, upperBound: upperBound, tokens: tokens),
            openParenthesisIndex + 1 < upperBound,
            tokens[openParenthesisIndex + 1].kind == .identifier
        else {
            return nil
        }
        return (tokens[openParenthesisIndex + 1].text, parameterType)
    }

    private static func lifecycleTypes(for annotations: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        if annotations.contains("system") {
            result["update"] = GravityAPICatalog.systemContextType
        }
        if annotations.contains("tool") {
            result["activate"] = GravityAPICatalog.editorToolContextType
        }
        return result
    }

    private static func nextLifecycleIdentifier(after index: Int, upperBound: Int, tokens: [GravityToken]) -> Int? {
        let candidate = index + 1
        guard candidate < upperBound, tokens[candidate].kind == .identifier else {
            return nil
        }
        return candidate
    }

    private static func nextLifecycleToken(_ text: String, after index: Int, upperBound: Int, tokens: [GravityToken]) -> Int? {
        var candidate = index + 1
        while candidate < upperBound {
            if tokens[candidate].text == text {
                return candidate
            }
            if tokens[candidate].text == ";" || tokens[candidate].text == "}" {
                return nil
            }
            candidate += 1
        }
        return nil
    }

    private static let typeKeywordNames: Set<String> = ["class", "enum", "struct"]
}
