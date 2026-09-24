/// Resolves AdaScript's additional `Math` functions without mutating the VM's shared native Math class.
public enum AdaScriptMathLowerer {
    private static let functions: [String: String] = [
        "clamp": "__adaMathClamp",
        "saturate": "__adaMathSaturate",
        "addVector": "__adaMathAddVector",
        "subtractVector": "__adaMathSubtractVector",
        "scaleVector": "__adaMathScaleVector",
        "dot": "__adaMathDot",
        "cross": "__adaMathCross",
        "length": "__adaMathLength",
        "normalize": "__adaMathNormalize",
        "distance": "__adaMathDistance",
        "lerpVector": "__adaMathLerpVector",
        "clampVector": "__adaMathClampVector",
        "identityMatrix": "__adaMathIdentityMatrix",
        "transposeMatrix": "__adaMathTransposeMatrix",
        "transformVector": "__adaMathTransformVector",
        "multiplyMatrix": "__adaMathMultiplyMatrix",
    ]

    public static func lower(source: String) -> String {
        var lexer = Lexer(source: source)
        let tokens = lexer.lex()
        let characters = Array(source)
        var replacements: [(range: Range<Int>, text: String)] = []

        for index in tokens.indices {
            guard
                tokens[index].kind == .identifier,
                tokens[index].text == "Math",
                index == 0 || tokens[index - 1].text != ".",
                tokens.indices.contains(index + 2),
                tokens[index + 1].text == ".",
                let function = functions[tokens[index + 2].text]
            else {
                continue
            }
            let range = tokens[index].startOffset..<tokens[index + 2].endOffset
            let lineBreaks = characters[range].filter { $0 == "\n" || $0 == "\r" }
            replacements.append((range, function + String(lineBreaks)))
        }

        var result = characters
        for replacement in replacements.reversed() {
            result.replaceSubrange(replacement.range, with: Array(replacement.text))
        }
        return String(result)
    }
}
