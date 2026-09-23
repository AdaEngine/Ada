import Foundation

/// Resolves AdaScript references to types supplied by the Swift host. AdaScript's
/// workspace index only contains script declarations, so these symbols need a
/// separate source index instead of a synthetic AdaScript definition.
enum AdaScriptSwiftSourceResolver {
    private struct Declaration: Hashable, Sendable {
        var fileURL: URL
        var line: Int
        var column: Int
        var name: String
    }

    private struct Reference {
        var name: String
        var range: EditorSourceRange
        var receiver: String?
    }

    private struct SourceIndex: Sendable {
        var types: [String: [Declaration]] = [:]
        var exportedTypes: [String: Declaration] = [:]
        var bridges: [Declaration] = []
    }

    private static let sourceIndex = indexSwiftTypes()
    private static let swiftTypeKeywords: Set<String> = ["actor", "class", "enum", "protocol", "struct", "typealias"]

    static func definition(text: String, position: EditorSourceLocation) -> EditorSourceSymbolTarget? {
        guard let reference = reference(in: text, at: position),
              let declaration = declaration(for: reference, in: text),
              let source = try? String(contentsOf: declaration.fileURL, encoding: .utf8) else {
            return nil
        }
        let sourceLines = source.components(separatedBy: .newlines)
        let selected: Declaration
        if reference.receiver != nil {
            var member = memberDeclaration(named: reference.name, in: sourceLines, after: declaration)
            if member == nil {
                for bridge in bridges(wrapping: declaration.name) {
                    guard let bridgeSource = try? String(contentsOf: bridge.fileURL, encoding: .utf8) else { continue }
                    member = memberDeclaration(named: reference.name, in: bridgeSource.components(separatedBy: .newlines), after: bridge)
                    if member != nil { break }
                }
            }
            guard let member else {
                return nil
            }
            selected = member
        } else {
            selected = declaration
        }
        let selectedLines = selected.fileURL == declaration.fileURL
            ? sourceLines
            : (try? String(contentsOf: selected.fileURL, encoding: .utf8))?.components(separatedBy: .newlines) ?? sourceLines
        let range = EditorSourceRange(
            start: EditorSourceLocation(line: selected.line, character: selected.column),
            end: EditorSourceLocation(line: selected.line, character: selected.column + selected.name.count)
        )
        return EditorSourceSymbolTarget(
            uri: selected.fileURL.absoluteString,
            filePath: selected.fileURL.path,
            range: range,
            selectionRange: range,
            documentation: documentation(for: selected, in: selectedLines, scriptName: reference.name)
        )
    }

    static func hover(text: String, position: EditorSourceLocation) -> EditorSymbolHover? {
        guard let reference = reference(in: text, at: position),
              let target = definition(text: text, position: position),
              let source = try? String(contentsOfFile: target.filePath, encoding: .utf8) else {
            return nil
        }
        let lines = source.components(separatedBy: .newlines)
        guard lines.indices.contains(target.selectionRange.start.line) else {
            return nil
        }
        let signature = lines[target.selectionRange.start.line].trimmingCharacters(in: .whitespaces)
        let description = target.documentation.map { "\n\n\($0)" } ?? ""
        return EditorSymbolHover(contents: "`\(signature)`\(description)", range: reference.range)
    }

    private static func declaration(for reference: Reference, in text: String) -> Declaration? {
        if let receiver = reference.receiver {
            let typeName = declaredType(of: receiver, in: text) ?? receiver
            return sourceIndex.types[typeName]?.first ?? sourceIndex.exportedTypes[typeName]
        }
        guard reference.name.first?.isUppercase == true else { return nil }
        return sourceIndex.types[reference.name]?.first ?? sourceIndex.exportedTypes[reference.name]
    }

    private static func declaredType(of variable: String, in text: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: variable)
        guard let expression = try? NSRegularExpression(pattern: "\\b(?:var|let)\\s+\(escapedName)\\s*:\\s*([A-Za-z_][A-Za-z_0-9]*)"),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let typeRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[typeRange])
    }

    private static func reference(in text: String, at position: EditorSourceLocation) -> Reference? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.indices.contains(position.line) else { return nil }
        let characters = Array(lines[position.line])
        guard characters.indices.contains(position.character) else { return nil }
        var start = position.character
        while start > 0, isIdentifierCharacter(characters[start - 1]) { start -= 1 }
        var end = position.character
        while end < characters.count, isIdentifierCharacter(characters[end]) { end += 1 }
        guard start < end else { return nil }
        let name = String(characters[start..<end])
        var receiver: String?
        if start > 0, characters[start - 1] == "." {
            var receiverStart = start - 1
            while receiverStart > 0, isIdentifierCharacter(characters[receiverStart - 1]) { receiverStart -= 1 }
            if receiverStart < start - 1 {
                receiver = String(characters[receiverStart..<(start - 1)])
            }
        }
        let range = EditorSourceRange(
            start: EditorSourceLocation(line: position.line, character: start),
            end: EditorSourceLocation(line: position.line, character: end)
        )
        return Reference(name: name, range: range, receiver: receiver)
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func indexSwiftTypes() -> SourceIndex {
        let editorSource = URL(fileURLWithPath: #filePath)
        let engineRoot = (0..<5).reduce(editorSource) { url, _ in url.deletingLastPathComponent() }
        let sources = engineRoot.appendingPathComponent("Sources", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            return SourceIndex()
        }
        var index = SourceIndex()
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let lines = source.components(separatedBy: .newlines)
            for (lineNumber, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                let words = code.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).map(String.init)
                guard let keywordIndex = words.firstIndex(where: swiftTypeKeywords.contains),
                      words.indices.contains(keywordIndex + 1) else { continue }
                let name = words[keywordIndex + 1]
                guard let nameRange = code.range(of: name, options: .backwards) else { continue }
                let column = code.distance(from: code.startIndex, to: nameRange.lowerBound)
                let declaration = Declaration(fileURL: fileURL, line: lineNumber, column: column, name: name)
                index.types[name, default: []].append(declaration)
                if let exportName = exportedName(before: lineNumber, in: lines) {
                    index.exportedTypes[exportName] = declaration
                    if exportName.hasPrefix("Ada"), exportName.count > 3 {
                        index.exportedTypes[String(exportName.dropFirst(3))] = declaration
                    }
                    index.bridges.append(declaration)
                }
            }
        }
        index.types = index.types.mapValues { $0.sorted { $0.fileURL.path < $1.fileURL.path } }
        return index
    }

    private static func exportedName(before line: Int, in lines: [String]) -> String? {
        guard line > 0 else { return nil }
        let attribute = lines[line - 1].trimmingCharacters(in: .whitespaces)
        guard attribute.hasPrefix("@GSExportable(\"") else { return nil }
        let value = attribute.dropFirst("@GSExportable(\"".count)
        guard let end = value.firstIndex(of: "\"") else { return nil }
        return String(value[..<end])
    }

    private static func bridges(wrapping typeName: String) -> [Declaration] {
        sourceIndex.bridges.filter { bridge in
            guard let source = try? String(contentsOf: bridge.fileURL, encoding: .utf8) else { return false }
            let lines = source.components(separatedBy: .newlines)
            guard lines.indices.contains(bridge.line) else { return false }
            let end = lines[(bridge.line + 1)...].firstIndex(of: "}") ?? lines.endIndex
            let body = lines[bridge.line..<end].joined(separator: "\n")
            let pattern = "\\b(?:var|let)\\s+[A-Za-z_][A-Za-z_0-9]*\\s*:\\s*" + NSRegularExpression.escapedPattern(for: typeName) + "\\b"
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
            return expression.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil
        }
    }

    private static func memberDeclaration(named name: String, in lines: [String], after type: Declaration) -> Declaration? {
        guard name.first?.isLowercase == true else { return nil }
        if let member = memberDeclaration(named: name, in: lines, fileURL: type.fileURL, after: type.line) {
            return member
        }
        guard let files = FileManager.default.enumerator(at: type.fileURL.deletingLastPathComponent(), includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let fileURL as URL in files where fileURL.pathExtension == "swift" && fileURL != type.fileURL {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
                  text.contains("extension \(type.name)") else { continue }
            if let member = memberDeclaration(named: name, in: text.components(separatedBy: .newlines), fileURL: fileURL, after: -1) {
                return member
            }
        }
        return nil
    }

    private static func memberDeclaration(named name: String, in lines: [String], fileURL: URL, after firstLine: Int) -> Declaration? {
        for lineNumber in (firstLine + 1)..<lines.count {
            let line = lines[lineNumber]
            guard let nameRange = line.range(of: name),
                  line[..<nameRange.lowerBound].contains(where: { $0 == " " || $0 == "\t" }),
                  line.contains("func \(name)") || line.contains("var \(name)") || line.contains("let \(name)") else {
                continue
            }
            let column = line.distance(from: line.startIndex, to: nameRange.lowerBound)
            return Declaration(fileURL: fileURL, line: lineNumber, column: column, name: name)
        }
        return nil
    }

    private static func documentation(for declaration: Declaration, in lines: [String], scriptName: String) -> String? {
        var comments: [String] = []
        var line = declaration.line - 1
        while line >= 0 {
            let trimmed = lines[line].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("///") else { break }
            comments.insert(String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces), at: 0)
            line -= 1
        }
        if !comments.isEmpty { return comments.joined(separator: "\n") }
        if sourceIndex.exportedTypes[scriptName] == declaration {
            return "AdaScript \(scriptName) bridge implemented by \(declaration.name)."
        }
        return nil
    }
}
