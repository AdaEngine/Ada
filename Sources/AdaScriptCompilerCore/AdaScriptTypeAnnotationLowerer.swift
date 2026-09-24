/// Removes analyzer-only function return annotations before source reaches the
/// dynamic AdaScript VM. Parameter and variable annotations are understood by
/// the VM and remain intact.
public enum AdaScriptTypeAnnotationLowerer {
    public static func lower(source: String) -> String {
        var lexer = Lexer(source: source)
        let tokens = lexer.lex()
        var replacements: [Range<Int>] = []
        var index = 0
        while index < tokens.count {
            guard tokens[index].text == "func", index + 2 < tokens.count else {
                index += 1
                continue
            }
            guard
                let openParenthesis = nextToken("(", after: index, tokens: tokens),
                let closeParenthesis = matchingIndex(
                    openingAt: openParenthesis,
                    opening: "(",
                    closing: ")",
                    tokens: tokens
                )
            else {
                index += 1
                continue
            }
            let annotationStart = closeParenthesis + 1
            guard
                annotationStart + 1 < tokens.count,
                tokens[annotationStart].text == "-",
                tokens[annotationStart + 1].text == ">"
            else {
                index = closeParenthesis + 1
                continue
            }
            guard let body = nextBodyToken(after: annotationStart + 1, tokens: tokens) else {
                index = annotationStart + 2
                continue
            }
            replacements.append(tokens[annotationStart].startOffset..<tokens[body].startOffset)
            index = body
        }

        var characters = Array(source)
        for range in replacements.reversed() {
            characters.replaceSubrange(range, with: repeatElement(Character(" "), count: range.count))
        }
        return String(characters)
    }

    private static func nextToken(_ text: String, after index: Int, tokens: [Token]) -> Int? {
        var cursor = index + 1
        while cursor < tokens.count {
            if tokens[cursor].text == text {
                return cursor
            }
            if tokens[cursor].text == ";" || tokens[cursor].text == "}" {
                return nil
            }
            cursor += 1
        }
        return nil
    }

    private static func nextBodyToken(after index: Int, tokens: [Token]) -> Int? {
        var cursor = index + 1
        while cursor < tokens.count {
            if tokens[cursor].text == "{" || tokens[cursor].text == ";" {
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    private static func matchingIndex(
        openingAt index: Int,
        opening: String,
        closing: String,
        tokens: [Token]
    ) -> Int? {
        var depth = 0
        for cursor in index..<tokens.count {
            if tokens[cursor].text == opening {
                depth += 1
            } else if tokens[cursor].text == closing {
                depth -= 1
                if depth == 0 {
                    return cursor
                }
            }
        }
        return nil
    }
}
