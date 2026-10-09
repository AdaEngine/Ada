import Foundation

/// Instruments community gameplay before compilation. Unsupported syntax fails closed.
/// This is a restricted scripting profile, not an operating-system process sandbox.
public enum AdaScriptCommunityLowerer {
    public static func validate(source: String) throws {
        // Interpolation can contain executable expressions hidden from this lexer.
        guard !source.contains("\\(") else { throw Failure.unsupportedSyntax }
        var lexer = Lexer(source: source)
        let tokens = lexer.lex()
        guard !tokens.contains(where: { $0.kind == .punctuation && $0.text == "'" }) else { throw Failure.unsupportedSyntax }
        let forbidden: Set<String> = ["System", "Fiber", "Class", "Object", "exit", "input", "extern", "view", "toClass", "AdaAssets", "AdaAsyncHost", "AdaAsyncOperation", "AdaAsyncResult", "AdaAttachedComponent", "AdaAttachedResource", "AdaCommands", "AdaComponent", "AdaComponentFactory", "AdaComponentValue", "AdaInputActions", "AdaMultiplayer", "AdaNetworkCommandFactory", "AdaNetworkCommandValue", "AdaNetworkValue", "AdaQuery", "AdaQueryRow", "AdaRemoteCommand", "AdaResource", "AdaSaveWriter", "AdaScriptableContext", "AdaSystemContext", "AdaTaskRuntime", "AdaUGCBudget", "AdaWorldContext"]
        let coreTypes: Set<String> = ["Math", "String", "List", "Map", "Int", "Float", "Bool", "Range", "Closure", "Function"]
        for index in tokens.indices where tokens[index].kind == .identifier {
            let token = tokens[index]
            if forbidden.contains(token.text) || token.text.hasPrefix("__") ||
                (token.text == "class" && index > 0 && tokens[index - 1].text == ".") {
                throw Failure.forbiddenAPI(token.text)
            }
            if coreTypes.contains(token.text) {
                let following = tokens.dropFirst(index + 1)
                let directCall = following.first?.text == "("
                let memberCall = following.count >= 3 && following.first?.text == "." && tokens[index + 3].text == "("
                let annotation = index > 0 && [":", "is"].contains(tokens[index - 1].text)
                guard directCall || memberCall || annotation else { throw Failure.forbiddenAPI("mutable core type " + token.text) }
            }
        }
    }

    public static func instrument(source: String) throws -> String {
        var lexer = Lexer(source: source)
        let tokens = lexer.lex()
        var insertions = Set<Int>()
        for index in tokens.indices where tokens[index].kind == .identifier && ["func", "while", "for", "repeat"].contains(tokens[index].text) {
            var cursor = index + 1
            var parentheses = 0
            var found = false
            while cursor < tokens.count {
                let text = tokens[cursor].text
                if text == "(" { parentheses += 1 }
                if text == ")" { parentheses -= 1 }
                if parentheses == 0 && text == "{" {
                    insertions.insert(tokens[cursor].endOffset)
                    found = true
                    break
                }
                if parentheses == 0 && text == ";" { break }
                cursor += 1
            }
            guard found else { throw Failure.unsupportedSyntax }
        }
        var characters = Array(source)
        let check = Array(" if (!__adaUGCBudget.check()) { Fiber.abort(\"Community execution limit exceeded\"); } ")
        for offset in insertions.sorted(by: >) { characters.insert(contentsOf: check, at: offset) }
        return String(characters)
    }

    public enum Failure: Error, LocalizedError {
        case forbiddenAPI(String)
        case unsupportedSyntax
        public var errorDescription: String? {
            switch self {
            case .forbiddenAPI(let name): "Community games cannot use \(name)."
            case .unsupportedSyntax: "This script uses syntax unsupported by the community player."
            }
        }
    }
}
