/// Prepares host conveniences for Gravity's native compiler without changing
/// annotated declarations or implementing a second language compiler.
public enum AdaScriptNativeSourceBuilder {
    public static func prepare(sources: [AdaScriptCompilerSource], constructors: [String: [String]]) throws -> [AdaScriptCompilerSource] {
        let schemas = try AdaScriptSchemaParser.parse(sources: sources)
        let commands = try AdaScriptSchemaParser.parseNetworkCommands(sources: sources)
        var calls = constructors.mapValues { ("__adaComponentFactory", $0) }
        for schema in schemas where schema.kind == .component { calls[schema.name] = ("__adaComponentFactory", schema.fields.map(\.name)) }
        for command in commands { calls[command.name] = ("__adaNetworkFactory", command.fields.map(\.name)) }
        let prepared = try sources.map { source in
            let layoutSource = AdaScriptSpriteLayoutLibrary.lowerForNative(source.source)
            let assetSource = AdaScriptAssetsLowerer.lower(source: layoutSource)
            let typedSource = AdaScriptTypeAnnotationLowerer.lower(source: assetSource)
            return AdaScriptCompilerSource(
                path: source.path,
                source: try lowerConstructors(
                    lowerRPCParameters(typedSource, commands: commands),
                    calls: calls
                )
            )
        }
        let globals = ["Assets", "multiplayer", "__adaAssets", "__adaComponentFactory", "__adaNetworkFactory", "Tasks", "Time", "__adaTaskFromOperation"]
        var declared = Set<String>()
        for source in prepared {
            var lexer = Lexer(source: source.source)
            let tokens = lexer.lex()
            for index in tokens.indices where index + 2 < tokens.count && tokens[index].text == "extern" && tokens[index + 1].text == "var" {
                declared.insert(tokens[index + 2].text)
            }
        }
        let prelude = globals.filter { !declared.contains($0) }.map { "extern var \($0);" }.joined(separator: "\n")
        return [AdaScriptCompilerSource(path: "NativeHost.ada", source: prelude + "\n" + AdaScriptSpriteLayoutLibrary.nativeSource)] + prepared
    }

    private static func lowerRPCParameters(_ source: String, commands: [AdaScriptNetworkCommandSchema]) -> String {
        var lexer = Lexer(source: source)
        let tokens = lexer.lex()
        var changes: [(Range<Int>, String)] = []
        for index in tokens.indices where index + 2 < tokens.count && tokens[index].text == "@" && tokens[index + 1].text == "rpc" {
            var declaration = index + 2
            if tokens[declaration].text == "(" {
                var depth = 1
                declaration += 1
                while declaration < tokens.count && depth > 0 {
                    if tokens[declaration].text == "(" { depth += 1 }
                    if tokens[declaration].text == ")" { depth -= 1 }
                    declaration += 1
                }
            }
            if declaration < tokens.count, tokens[declaration].text == "async" { declaration += 1 }
            guard declaration + 2 < tokens.count, tokens[declaration].text == "func",
                let schema = commands.first(where: { $0.name == tokens[declaration + 1].text })
            else { continue }
            let open = declaration + 2
            var end = open + 1
            var depth = 1
            while end < tokens.count && depth > 0 {
                if tokens[end].text == "(" { depth += 1 }
                if tokens[end].text == ")" { depth -= 1 }
                if depth == 0 { break }
                end += 1
            }
            guard depth == 0, end + 1 < tokens.count else { continue }
            changes.append((tokens[open].endOffset..<tokens[end].startOffset, (["source"] + schema.fields.map(\.name)).joined(separator: ", ")))
            if tokens[end + 1].text == ";" { changes.append((tokens[end + 1].startOffset..<tokens[end + 1].endOffset, "{}")) }
        }
        var result = Array(source)
        for (range, replacement) in changes.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) { result.replaceSubrange(range, with: Array(replacement)) }
        return String(result)
    }

    private static func lowerConstructors(_ source: String, calls: [String: (String, [String])]) throws -> String {
        var lexer = Lexer(source: source)
        let tokens = lexer.lex()
        let characters = Array(source)
        var replacements: [(Range<Int>, String)] = []
        for index in tokens.indices where index + 1 < tokens.count {
            guard let (factory, fields) = calls[tokens[index].text], tokens[index + 1].text == "(",
                index == 0 || !["func", ".", "class", "struct"].contains(tokens[index - 1].text)
            else { continue }
            var depth = 1
            var end = index + 2
            var starts = [end]
            var ends: [Int] = []
            while end < tokens.count && depth > 0 {
                let text = tokens[end].text
                if ["(", "[", "{"].contains(text) { depth += 1 }
                if [")", "]", "}"].contains(text) { depth -= 1 }
                if depth == 1 && text == "," {
                    ends.append(end)
                    starts.append(end + 1)
                }
                if depth == 0 {
                    ends.append(end)
                    break
                }
                end += 1
            }
            guard depth == 0 else { throw NativeSourceError("Unterminated constructor '\(tokens[index].text)'") }
            var arguments = [String](repeating: "null", count: fields.count)
            var assigned = Set<Int>()
            for (position, bounds) in zip(starts, ends).enumerated() {
                var (first, last) = bounds
                guard first < last else { continue }
                let field: Int
                if first + 1 < last && tokens[first + 1].text == ":" {
                    guard let found = fields.firstIndex(of: tokens[first].text) else { throw NativeSourceError("Unknown constructor field '\(tokens[first].text)'") }
                    field = found
                    first += 2
                } else {
                    field = position
                }
                guard field < fields.count, assigned.insert(field).inserted, first < last else { throw NativeSourceError("Invalid constructor arguments for '\(tokens[index].text)'") }
                last -= 1
                arguments[field] = String(characters[tokens[first].startOffset..<tokens[last].endOffset])
            }
            let expression = "\(factory).makeNamed(\"\(tokens[index].text)\", [\(arguments.joined(separator: ", "))])"
            replacements.append((tokens[index].startOffset..<tokens[end].endOffset, expression))
        }
        // Nested constructor replacements are applied recursively through the
        // original argument expressions rather than overlapping source ranges.
        let outer = replacements.filter { candidate in
            !replacements.contains { other in other.0 != candidate.0 && other.0.lowerBound < candidate.0.lowerBound && other.0.upperBound > candidate.0.upperBound }
        }
        var result = characters
        for (range, expression) in outer.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            // Process nested calls in the arguments; skip this generated factory call.
            result.replaceSubrange(range, with: Array(try lowerNested(expression, calls: calls)))
        }
        return String(result)
    }
    private static func lowerNested(_ source: String, calls: [String: (String, [String])]) throws -> String {
        try lowerConstructors(source, calls: calls)
    }
}

private struct NativeSourceError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
