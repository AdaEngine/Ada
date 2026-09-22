/// Adds the statically declared asset type to `Assets.load` and
/// `Assets.preload` calls before the dynamically typed VM compiles them.
public enum AdaScriptAssetsLowerer {
    private struct Replacement {
        var endOffset: Int
        var source: String
        var startOffset: Int
    }

    public static func lower(source: String) -> String {
        var lexer = Lexer(source: source)
        let tokens = lexer.lex()
        let characters = Array(source)
        var replacements: [Replacement] = []
        var typedCalls: [Int: (typeName: String, annotationRange: Range<Int>)] = [:]

        for index in tokens.indices where tokens[index].text == "var" {
            guard
                tokens.indices.contains(index + 8),
                tokens[index + 2].text == ":",
                tokens[index + 3].kind == .identifier,
                tokens[index + 4].text == "=",
                tokens[index + 5].text == "Assets",
                tokens[index + 6].text == ".",
                ["load", "preload"].contains(tokens[index + 7].text),
                tokens[index + 8].text == "("
            else {
                continue
            }
            typedCalls[index + 5] = (
                typeName: tokens[index + 3].text,
                annotationRange: tokens[index + 2].startOffset..<tokens[index + 3].endOffset
            )
        }

        for index in tokens.indices where tokens[index].text == "Assets" {
            guard
                tokens.indices.contains(index + 3),
                tokens[index + 1].text == ".",
                ["load", "preload", "save"].contains(tokens[index + 2].text),
                tokens[index + 3].text == "(",
                let closingIndex = matchingClosingParenthesis(openingAt: index + 3, tokens: tokens)
            else {
                continue
            }
            let operation: String
            if let typed = typedCalls[index] {
                operation = "\"loadTyped\", \"\(typed.typeName)\", "
                replacements.append(
                    Replacement(endOffset: typed.annotationRange.upperBound, source: "", startOffset: typed.annotationRange.lowerBound)
                )
            } else {
                operation = tokens[index + 2].text == "save" ? "\"save\", " : "\"load\", "
            }
            replacements.append(
                Replacement(
                    endOffset: tokens[index + 3].endOffset,
                    source: "__adaAssets.perform([\(operation)",
                    startOffset: tokens[index].startOffset
                )
            )
            replacements.append(
                Replacement(endOffset: tokens[closingIndex].startOffset, source: "]", startOffset: tokens[closingIndex].startOffset)
            )
        }

        var result = characters
        for replacement in replacements.sorted(by: { $0.startOffset > $1.startOffset }) {
            result.replaceSubrange(replacement.startOffset..<replacement.endOffset, with: Array(replacement.source))
        }
        return String(result)
    }

    private static func matchingClosingParenthesis(openingAt openingIndex: Int, tokens: [Token]) -> Int? {
        var depth = 0
        for index in openingIndex..<tokens.count {
            if tokens[index].text == "(" {
                depth += 1
            } else if tokens[index].text == ")" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
        }
        return nil
    }
}
