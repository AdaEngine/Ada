#if !os(WASI)
import Foundation

struct WESLLinker {
    let roots: [String: URL]
    let features: [String: Bool]
    /// Module source supplied in memory, by module path. It replaces (or stands in for) the module's file, so generated
    /// source can import siblings from the package without being written under the package root.
    var sourceOverrides: [String: String] = [:]
    private var modules: [String: Module] = [:]
    private var loading: Set<String> = []
    private var ordered: [String] = []

    init(roots: [String: URL], features: [String: Bool]) {
        self.roots = roots
        self.features = features
    }

    mutating func link(_ entry: String) throws -> (wgsl: String, sources: [String]) {
        guard roots.keys.allSatisfy(isIdentifier), roots["super"] == nil else {
            throw Failure("WESL package names must be identifiers other than super")
        }
        guard features.keys.allSatisfy(isIdentifier) else {
            throw Failure("WESL feature names must be identifiers")
        }
        try load(entry)
        var directives: Set<String> = []
        var declarations: [String] = []
        for path in ordered {
            guard let module = modules[path] else { continue }
            directives.formUnion(module.directives)
            let names = try names(for: module, rootModule: entry)
            try declarations.append(rewrite(module, names: names, rootModule: entry))
        }
        return (
            wgsl: (directives.sorted() + declarations).joined(separator: "\n"),
            sources: ordered.compactMap { modules[$0]?.file.path }
        )
    }

    private mutating func load(_ path: String) throws {
        if modules[path] != nil { return }
        guard loading.count < 128 else { throw Failure("WESL import nesting limit exceeded at \(path)") }
        guard loading.insert(path).inserted else { throw Failure("Cyclic WESL import: \(path)") }
        defer { loading.remove(path) }
        let file: URL
        let text: String
        if let override = sourceOverrides[path] {
            file = (try? moduleFile(path)) ?? (roots["package"] ?? URL(fileURLWithPath: "/")).appendingPathComponent("generated.wesl")
            text = override
        } else {
            file = try moduleFile(path)
            text = try String(contentsOf: file, encoding: .utf8)
        }
        let raw = try tokenize(text, file: file)
        let conditions = WESLConditions(tokens: raw, features: features, file: file)
        let tokens = try conditions.expand()
        var cursor = 0
        var imports: [Import] = []
        while tokens.indices.contains(cursor), tokens[cursor] == "import" {
            cursor += 1
            try parseImports(tokens, cursor: &cursor, prefix: [], into: &imports, file: file)
            guard tokens.indices.contains(cursor), tokens[cursor] == ";" else {
                throw Failure("Expected ';' after import in \(file.path)")
            }
            cursor += 1
        }
        var moduleAliases: [String: String] = [:]
        var items: [String: Reference] = [:]
        for item in imports {
            let qualified = try absolutePath(item.parts, in: path, file: file)
            let alias = item.alias ?? item.parts.last ?? ""
            guard moduleAliases[alias] == nil, items[alias] == nil else {
                throw Failure("Duplicate import '\(alias)' in \(file.path)")
            }
            if (try? moduleFile(qualified)) != nil {
                try load(qualified)
                moduleAliases[alias] = qualified
            } else {
                let parts = qualified.components(separatedBy: "::")
                guard parts.count >= 2, let name = parts.last else { throw Failure("Invalid import in \(file.path)") }
                let owner = parts.dropLast().joined(separator: "::")
                try load(owner)
                guard modules[owner]?.globals.values.contains(name) == true else {
                    throw Failure("Imported declaration '\(qualified)' not found in \(file.path)")
                }
                items[alias] = Reference(module: owner, name: name)
            }
        }
        var directives: [String] = []
        while tokens.indices.contains(cursor), ["enable", "requires", "diagnostic"].contains(tokens[cursor]) {
            guard let end = tokens[cursor...].firstIndex(of: ";") else {
                throw Failure("Incomplete directive in \(file.path)")
            }
            directives.append(tokens[cursor...end].joined(separator: " "))
            cursor = end + 1
        }
        let body = Array(tokens[cursor...])
        let globals = try globalNames(body, file: file)
        var position = 0
        while position + 1 < body.count {
            guard body[position + 1] == "::" else { position += 1; continue }
            let reference = qualifiedReference(body, at: position)
            let anchor = reference.parts[0]
            let qualified = if let alias = moduleAliases[anchor] {
                ([alias] + reference.parts.dropFirst()).joined(separator: "::")
            } else {
                try absolutePath(reference.parts, in: path, file: file)
            }
            let owner = qualified.components(separatedBy: "::").dropLast().joined(separator: "::")
            if owner != path { try load(owner) }
            position = reference.end
        }
        modules[path] = Module(path: path, file: file, tokens: body, globals: globals, items: items,
                               aliases: moduleAliases, directives: directives)
        ordered.append(path)
    }

    private func moduleFile(_ path: String) throws -> URL {
        let parts = path.components(separatedBy: "::")
        guard let name = parts.first, let root = roots[name], parts.dropFirst().allSatisfy(isIdentifier) else {
            throw Failure("Invalid WESL module path: \(path)")
        }
        let components = parts.count == 1 ? ["package"] : Array(parts.dropFirst())
        let base = components.reduce(root) { $0.appendingPathComponent($1) }
        for ext in ["wesl", "wgsl"] {
            let file = base.appendingPathExtension(ext).resolvingSymlinksInPath().standardizedFileURL
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard file.path.hasPrefix(prefix) else { throw Failure("WESL module escapes the package root: \(path)") }
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return file }
        }
        throw Failure("WESL module '\(path)' not found under \(root.path)")
    }

    private func absolutePath(_ parts: [String], in module: String, file: URL) throws -> String {
        let current = module.components(separatedBy: "::")
        if parts.first == "package", let name = current.first {
            return ([name] + parts.dropFirst()).joined(separator: "::")
        }
        if let name = parts.first, roots[name] != nil {
            return parts.joined(separator: "::")
        }
        let parents = parts.prefix { $0 == "super" }.count
        guard parents > 0, parents < current.count else {
            throw Failure("Expected package::, a registered dependency, or a valid super:: path in \(file.path)")
        }
        return (Array(current.dropLast(parents)) + parts.dropFirst(parents)).joined(separator: "::")
    }

    private func parseImports(
        _ tokens: [String], cursor: inout Int, prefix: [String], into imports: inout [Import], file: URL,
        depth: Int = 0
    ) throws {
        guard depth < 128 else { throw Failure("WESL import is too deeply nested in \(file.path)") }
        guard tokens.indices.contains(cursor) else { throw Failure("Incomplete import in \(file.path)") }
        if tokens[cursor] == "{" {
            cursor += 1
            while tokens.indices.contains(cursor), tokens[cursor] != "}" {
                try parseImports(tokens, cursor: &cursor, prefix: prefix, into: &imports, file: file, depth: depth + 1)
                if tokens.indices.contains(cursor), tokens[cursor] == "," { cursor += 1 }
                else { break }
            }
            guard tokens.indices.contains(cursor), tokens[cursor] == "}" else {
                throw Failure("Expected '}' in grouped import in \(file.path)")
            }
            cursor += 1
            return
        }
        let segment = tokens[cursor]
        guard isIdentifier(segment) else { throw Failure("Expected an explicit import name in \(file.path)") }
        cursor += 1
        if tokens.indices.contains(cursor), tokens[cursor] == "::" {
            cursor += 1
            try parseImports(tokens, cursor: &cursor, prefix: prefix + [segment], into: &imports, file: file, depth: depth + 1)
            return
        }
        var alias: String?
        if tokens.indices.contains(cursor), tokens[cursor] == "as" {
            cursor += 1
            guard tokens.indices.contains(cursor), isIdentifier(tokens[cursor]) else {
                throw Failure("Expected import alias in \(file.path)")
            }
            alias = tokens[cursor]
            cursor += 1
        }
        imports.append(Import(parts: prefix + [segment], alias: alias))
    }

    private func names(for module: Module, rootModule: String) throws -> [String: String] {
        var result = module.items.mapValues { emittedName($0.name, in: $0.module, rootModule: rootModule) }
        for name in module.globals.values {
            guard result[name] == nil, module.aliases[name] == nil else {
                throw Failure("Declaration '\(name)' conflicts with an import in \(module.file.path)")
            }
            result[name] = emittedName(name, in: module.path, rootModule: rootModule)
        }
        return result
    }

    private func emittedName(_ name: String, in module: String, rootModule: String) -> String {
        guard module != rootModule else { return name }
        let path = module.components(separatedBy: "::").map { "\($0.utf8.count)_\($0)" }.joined(separator: "_")
        return "ada_wesl_\(path)_\(name)"
    }

    private func rewrite(_ module: Module, names: [String: String], rootModule: String) throws -> String {
        var result: [String] = []
        let tokens = module.tokens
        let rootGlobals = Set(modules[rootModule]?.globals.values.map { $0 } ?? [])
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let preceding = index > 0 ? tokens[index - 1] : ""
            let next = index + 1 < tokens.count ? tokens[index + 1] : ""
            if next == "::", preceding != "." {
                let (parts, end) = qualifiedReference(tokens, at: index)
                let qualified = if let alias = module.aliases[token] {
                    ([alias] + parts.dropFirst()).joined(separator: "::")
                } else {
                    try absolutePath(parts, in: module.path, file: module.file)
                }
                let path = qualified.components(separatedBy: "::")
                let owner = path.dropLast().joined(separator: "::")
                guard let name = path.last, modules[owner]?.globals.values.contains(name) == true else {
                    throw Failure("Unresolved qualified name '\(qualified)' in \(module.file.path)")
                }
                result.append(emittedName(name, in: owner, rootModule: rootModule))
                index = end
            } else {
                if module.globals[index] != nil {
                    result.append(names[token] ?? token)
                } else if preceding == "." || preceding == "@" {
                    result.append(token)
                } else {
                    if names[token] != nil, next == ":" || ["let", "const", "var"].contains(preceding) {
                        throw Failure("Local declaration '\(token)' shadows a WESL binding in \(module.file.path)")
                    }
                    if module.path != rootModule, names[token] == nil, rootGlobals.contains(token) {
                        throw Failure("Name '\(token)' is not imported in \(module.file.path)")
                    }
                    result.append(names[token] ?? token)
                }
                index += 1
            }
        }
        return result.joined(separator: " ")
    }

    private func qualifiedReference(_ tokens: [String], at start: Int) -> (parts: [String], end: Int) {
        var parts = [tokens[start]]
        var end = start + 1
        while end + 1 < tokens.count, tokens[end] == "::", isIdentifier(tokens[end + 1]) {
            parts.append(tokens[end + 1])
            end += 2
        }
        return (parts, end)
    }

    private func globalNames(_ tokens: [String], file: URL) throws -> [Int: String] {
        var names: Set<String> = []
        var declarations: [Int: String] = [:]
        var depth = 0
        for (index, token) in tokens.enumerated() {
            if token == "{" { depth += 1 }
            if token == "}" { depth -= 1 }
            if depth == 0, ["fn", "struct", "alias", "const", "override", "var"].contains(token) {
                var nameIndex = index + 1
                if token == "var", tokens.indices.contains(nameIndex), tokens[nameIndex] == "<" {
                    guard let end = tokens[nameIndex...].firstIndex(of: ">") else { continue }
                    nameIndex = end + 1
                }
                guard tokens.indices.contains(nameIndex), isIdentifier(tokens[nameIndex]) else { continue }
                let name = tokens[nameIndex]
                guard !name.hasPrefix("ada_wesl_"), names.insert(name).inserted else {
                    throw Failure("Duplicate or reserved global name '\(name)' in \(file.path)")
                }
                declarations[nameIndex] = name
            }
        }
        return declarations
    }

    private struct Module {
        let path: String
        let file: URL
        let tokens: [String]
        let globals: [Int: String]
        let items: [String: Reference]
        let aliases: [String: String]
        let directives: [String]
    }

    private struct Import {
        let parts: [String]
        let alias: String?
    }

    private struct Reference {
        let module: String
        let name: String
    }

    struct Failure: LocalizedError, CustomStringConvertible {
        let description: String
        var errorDescription: String? { description }

        init(_ description: String) {
            self.description = description
        }
    }
}

private func isIdentifier(_ text: String) -> Bool {
    guard let first = text.first, first == "_" || first.isLetter else { return false }
    return text.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
}

private func tokenize(_ source: String, file: URL) throws -> [String] {
    let chars = Array(source)
    var index = 0
    var tokens: [String] = []
    while index < chars.count {
        let current = chars[index]
        let next = index + 1 < chars.count ? chars[index + 1] : " "
        let start = index
        if current.isWhitespace {
            index += 1
            continue
        }
        if current == "/", next == "/" {
            while index < chars.count, !chars[index].isNewline { index += 1 }
            continue
        }
        if current == "/", next == "*" {
            index += 2
            var depth = 1
            while index + 1 < chars.count, depth > 0 {
                if chars[index] == "/", chars[index + 1] == "*" { depth += 1; index += 2 }
                else if chars[index] == "*", chars[index + 1] == "/" { depth -= 1; index += 2 }
                else { index += 1 }
            }
            guard depth == 0 else { throw WESLLinker.Failure("Unterminated comment in \(file.path)") }
            continue
        }
        index += 1
        if current.isLetter || current == "_" {
            while index < chars.count, chars[index].isLetter || chars[index].isNumber || chars[index] == "_" { index += 1 }
        } else if current.isNumber || (current == "." && next.isNumber) {
            while index < chars.count {
                let char = chars[index]
                if char.isLetter || char.isNumber || char == "." ||
                    ((char == "+" || char == "-") && "eEpP".contains(chars[index - 1])) {
                    index += 1
                } else { break }
            }
        } else {
            let pair = String([current, next])
            if ["::", "->", "&&", "||", "==", "!=", "<=", ">=", "<<", ">>", "++", "--",
                "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^="].contains(pair) {
                index += 1
                if (pair == "<<" || pair == ">>"), index < chars.count, chars[index] == "=" { index += 1 }
            }
        }
        tokens.append(String(chars[start..<index]))
    }
    return tokens
}
#endif
