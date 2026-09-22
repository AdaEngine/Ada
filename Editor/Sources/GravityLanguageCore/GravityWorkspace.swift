import Foundation

public final class GravityWorkspace {
    private struct Document {
        var analysis: GravityDocumentAnalysis
        var text: String
        var version: Int?
    }

    private let fileManager: FileManager
    private var languageService: GravityLanguageService
    private var diskDocuments: [String: Document] = [:]
    private var openDocuments: [String: Document] = [:]
    private var rootURLs: [URL] = []

    public init(
        fileManager: FileManager = .default,
        hostConstructors: [GravityHostConstructor] = []
    ) {
        self.fileManager = fileManager
        self.languageService = GravityLanguageService(hostConstructors: hostConstructors)
    }

    public func setHostConstructors(_ constructors: [GravityHostConstructor]) {
        languageService = GravityLanguageService(hostConstructors: constructors)
    }

    public func configure(rootURIs: [String]) {
        rootURLs = rootURIs.compactMap(Self.fileURL(from:))
        openDocuments.removeAll(keepingCapacity: true)
        reloadDiskDocuments()
    }

    public func open(uri: String, text: String, version: Int?) {
        openDocuments[Self.documentKey(uri)] = document(text: text, version: version)
    }

    public func change(uri: String, text: String, version: Int?) {
        openDocuments[Self.documentKey(uri)] = document(text: text, version: version)
    }

    public func close(uri: String) {
        let key = Self.documentKey(uri)
        openDocuments.removeValue(forKey: key)
        if let url = Self.fileURL(from: uri), let text = try? String(contentsOf: url, encoding: .utf8) {
            diskDocuments[key] = document(text: text, version: nil)
        } else {
            diskDocuments.removeValue(forKey: key)
        }
    }

    public func save(uri: String, text: String?) {
        let key = Self.documentKey(uri)
        if let text {
            if let document = openDocuments[key] {
                openDocuments[key] = self.document(text: text, version: document.version)
            }
            diskDocuments[key] = document(text: text, version: nil)
        } else if let url = Self.fileURL(from: uri), let diskText = try? String(contentsOf: url, encoding: .utf8) {
            diskDocuments[key] = document(text: diskText, version: nil)
        }
    }

    public func text(for uri: String) -> String? {
        let key = Self.documentKey(uri)
        return openDocuments[key]?.text ?? diskDocuments[key]?.text
    }

    public func analysis(for uri: String) -> GravityDocumentAnalysis? {
        let key = Self.documentKey(uri)
        guard var analysis = (openDocuments[key] ?? diskDocuments[key])?.analysis else {
            return nil
        }
        analysis.diagnostics += importDiagnostics(uri: key, imports: analysis.imports)
        return analysis
    }

    public func completions(uri: String, position: GravitySourcePosition) -> [GravityCompletion] {
        guard let text = text(for: uri) else {
            return []
        }
        if let resource = resourceCompletionContext(text: text, position: position) {
            return resourceCompletions(context: resource)
        }
        return languageService.completions(
            text: text,
            position: position,
            workspaceSymbols: workspaceSymbols(for: uri)
        )
    }

    private struct ResourceCompletionContext {
        var prefix: String
        var replacementRange: GravitySourceRange
    }

    private func resourceCompletionContext(
        text: String,
        position: GravitySourcePosition
    ) -> ResourceCompletionContext? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.indices.contains(position.line) else {
            return nil
        }
        let line = String(lines[position.line])
        guard let caret = line.stringIndex(atUTF16Offset: position.utf16Column) else {
            return nil
        }
        let beforeCaret = line[..<caret]
        guard
            let quote = beforeCaret.lastIndex(where: { $0 == "\"" || $0 == "'" }),
            beforeCaret[beforeCaret.index(after: quote)...].contains("@res:")
        else {
            return nil
        }
        let contentStart = beforeCaret.index(after: quote)
        let prefix = String(beforeCaret[contentStart...])
        guard prefix.hasPrefix("@res:") else {
            return nil
        }
        return ResourceCompletionContext(
            prefix: prefix,
            replacementRange: GravitySourceRange(
                start: GravitySourcePosition(
                    line: position.line,
                    utf16Column: line[..<contentStart].utf16.count
                ),
                end: position
            )
        )
    }

    private func resourceCompletions(context: ResourceCompletionContext) -> [GravityCompletion] {
        let normalizedPrefix = context.prefix == "@res:" ? "@res://" : context.prefix
        return resourcePaths()
            .filter { $0.localizedCaseInsensitiveContains(normalizedPrefix) }
            .map { path in
                GravityCompletion(
                    label: path,
                    detail: "Project asset",
                    insertText: path,
                    kind: .variable,
                    replacementRange: context.replacementRange,
                    sortText: path.hasPrefix(normalizedPrefix) ? "00" : "10"
                )
            }
    }

    private func resourcePaths() -> [String] {
        var paths = Set<String>()
        for root in rootURLs {
            for directoryName in ["Assets", "Resources"] {
                let assetsURL = root.appendingPathComponent(directoryName, isDirectory: true)
                guard
                    let enumerator = fileManager.enumerator(
                        at: assetsURL,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    )
                else {
                    continue
                }
                for case let fileURL as URL in enumerator {
                    guard
                        let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]),
                        values.isDirectory != true
                    else {
                        continue
                    }
                    let rootPath = assetsURL.standardizedFileURL.path
                    let filePath = fileURL.standardizedFileURL.path
                    guard filePath.hasPrefix(rootPath + "/") else {
                        continue
                    }
                    paths.insert("@res://" + String(filePath.dropFirst(rootPath.count + 1)))
                }
            }
        }
        return paths.sorted()
    }

    public func semanticTokens(uri: String) -> [GravitySemanticToken] {
        guard let text = text(for: uri) else {
            return []
        }
        return languageService.semanticTokens(text: text)
    }

    public func hover(uri: String, position: GravitySourcePosition) -> GravityHover? {
        guard let text = text(for: uri) else {
            return nil
        }
        if let hover = languageService.hover(text: text, position: position) {
            return hover
        }
        guard
            let target = definition(uri: uri, position: position),
            let analysis = analysis(for: target.uri),
            let symbol = (analysis.symbols + analysis.symbols.flatMap(\.members))
                .first(where: {
                    $0.selectionRange == target.selectionRange
                }),
            let token = GravityDocumentAnalyzer.parse(text).tokens
                .first(where: {
                    $0.kind == .identifier && $0.range.contains(position)
                })
        else {
            return nil
        }
        return GravityHover(contents: "\(symbol.detail) \(symbol.name)", range: token.range)
    }

    public func signatureHelp(uri: String, position: GravitySourcePosition) -> GravitySignatureHelp? {
        guard let text = text(for: uri) else {
            return nil
        }
        return languageService.signatureHelp(text: text, position: position)
    }

    public func definition(uri: String, position: GravitySourcePosition) -> GravityDefinition? {
        let key = Self.documentKey(uri)
        guard let document = openDocuments[key] ?? diskDocuments[key] else {
            return nil
        }
        let parsed = GravityDocumentAnalyzer.parse(document.text)
        guard
            let tokenIndex = parsed.tokens.firstIndex(where: {
                $0.kind == .identifier && $0.range.contains(position)
            })
        else {
            return nil
        }

        let token = parsed.tokens[tokenIndex]
        let workspaceSymbols = locatedWorkspaceSymbols(for: key)
        if tokenIndex >= 2, parsed.tokens[tokenIndex - 1].text == "." {
            let receiver = parsed.tokens[tokenIndex - 2].text
            let typeName: String?
            if receiver == "this" {
                typeName = GravityDocumentAnalyzer.typeContaining(position, in: parsed.typeRegions)?.name
            } else {
                typeName = parsed.inferredTypes[receiver] ?? receiver
            }
            if let typeName,
                let locatedType = locatedSymbol(named: typeName, localURI: key, localSymbols: parsed.analysis.symbols, workspaceSymbols: workspaceSymbols),
                let member = locatedType.symbol.members.first(where: { $0.name == token.text }) {
                return Self.definition(uri: locatedType.uri, symbol: member)
            }
        }

        if let containingType = GravityDocumentAnalyzer.typeContaining(position, in: parsed.typeRegions),
            let member = containingType.members.first(where: { $0.name == token.text }) {
            return Self.definition(uri: key, symbol: member)
        }
        guard
            let located = locatedSymbol(
                named: token.text,
                localURI: key,
                localSymbols: parsed.analysis.symbols,
                workspaceSymbols: workspaceSymbols
            )
        else {
            return nil
        }
        return Self.definition(uri: located.uri, symbol: located.symbol)
    }

    public func refreshFile(uri: String) {
        let key = Self.documentKey(uri)
        guard
            openDocuments[key] == nil,
            let url = Self.fileURL(from: uri),
            Self.isGravitySource(url),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return
        }
        diskDocuments[key] = document(text: text, version: nil)
    }

    public func removeFile(uri: String) {
        let key = Self.documentKey(uri)
        guard openDocuments[key] == nil else {
            return
        }
        diskDocuments.removeValue(forKey: key)
    }

    private func workspaceSymbols(for uri: String) -> [GravitySymbol] {
        locatedWorkspaceSymbols(for: uri).map(\.symbol)
    }

    private func locatedWorkspaceSymbols(for uri: String) -> [(uri: String, symbol: GravitySymbol)] {
        let key = Self.documentKey(uri)
        var located = locatedImportedSymbols(for: key)
        let importedKeys = Set(located.map { "\($0.uri):\($0.symbol.kind.rawValue):\($0.symbol.name)" })
        let documents = diskDocuments.merging(openDocuments) { _, open in open }
        for documentURI in documents.keys.sorted() where documentURI != key {
            guard let document = documents[documentURI] else {
                continue
            }
            located += document.analysis.symbols.compactMap { symbol in
                let symbolKey = "\(documentURI):\(symbol.kind.rawValue):\(symbol.name)"
                return importedKeys.contains(symbolKey) ? nil : (uri: documentURI, symbol: symbol)
            }
        }
        return located
    }

    private func locatedImportedSymbols(for uri: String) -> [(uri: String, symbol: GravitySymbol)] {
        let key = Self.documentKey(uri)
        guard let document = openDocuments[key] ?? diskDocuments[key] else {
            return []
        }
        var symbols: [(uri: String, symbol: GravitySymbol)] = []
        for scriptImport in document.analysis.imports {
            guard case let .source(importedURI, importedDocument) = resolve(scriptImport, from: key) else {
                continue
            }
            if let namespace = scriptImport.namespace {
                symbols.append(
                    (
                        uri: importedURI,
                        symbol: GravitySymbol(
                            name: namespace,
                            kind: .class,
                            detail: "Imported AdaScript module",
                            range: scriptImport.range,
                            members: importedDocument.analysis.symbols
                        )
                    )
                )
            } else {
                let selectedNames = Set(scriptImport.names)
                symbols += importedDocument.analysis.symbols
                    .filter { selectedNames.contains($0.name) }
                    .map { (uri: importedURI, symbol: $0) }
            }
        }
        return symbols
    }

    private func locatedSymbol(
        named name: String,
        localURI: String,
        localSymbols: [GravitySymbol],
        workspaceSymbols: [(uri: String, symbol: GravitySymbol)]
    ) -> (uri: String, symbol: GravitySymbol)? {
        if let symbol = localSymbols.first(where: { $0.name == name }) {
            return (localURI, symbol)
        }
        return workspaceSymbols.first(where: { $0.symbol.name == name })
    }

    private func importDiagnostics(uri: String, imports: [GravityImport]) -> [GravityDiagnostic] {
        imports.compactMap { scriptImport in
            switch resolve(scriptImport, from: uri) {
            case .source,
                .virtual:
                nil
            case let .invalid(message):
                GravityDiagnostic(message: message, range: scriptImport.range)
            }
        }
    }

    private func resolve(_ scriptImport: GravityImport, from importerURI: String) -> ImportResolution {
        if Self.virtualModuleNames.contains(scriptImport.path) {
            return .virtual
        }
        guard scriptImport.path.hasPrefix("./") || scriptImport.path.hasPrefix("../") else {
            return .invalid("Imports must be relative or name a supported virtual module")
        }
        guard let importerURL = Self.fileURL(from: importerURI) else {
            return .invalid("Unable to resolve import from a non-file document")
        }

        var importedURL = importerURL.deletingLastPathComponent()
            .appendingPathComponent(scriptImport.path)
            .standardizedFileURL
        if importedURL.pathExtension.isEmpty {
            importedURL.appendPathExtension("ada")
        }
        guard rootURLs.contains(where: { Self.contains(importedURL, in: $0) }) else {
            return .invalid("Import escapes the configured AdaScript workspace")
        }

        let importedURI = importedURL.absoluteString
        guard let document = openDocuments[importedURI] ?? diskDocuments[importedURI] else {
            return .invalid("Unable to resolve import '\(scriptImport.path)'")
        }
        return .source(importedURI, document)
    }

    private func document(text: String, version: Int?) -> Document {
        Document(analysis: languageService.analyze(text: text), text: text, version: version)
    }

    private func reloadDiskDocuments() {
        diskDocuments.removeAll(keepingCapacity: true)
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        for rootURL in rootURLs {
            guard
                let enumerator = fileManager.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys: resourceKeys,
                    options: []
                )
            else {
                continue
            }
            for case let fileURL as URL in enumerator {
                if Self.skippedDirectoryNames.contains(fileURL.lastPathComponent),
                    (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard
                    Self.isGravitySource(fileURL),
                    (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                    let text = try? String(contentsOf: fileURL, encoding: .utf8)
                else {
                    continue
                }
                diskDocuments[fileURL.standardizedFileURL.absoluteString] = document(text: text, version: nil)
            }
        }
    }

    private static let skippedDirectoryNames: Set<String> = [".build", ".codex", ".git", ".swiftpm", "DerivedData"]
    private static let virtualModuleNames: Set<String> = ["AdaEngine", "AdaUI"]

    private static func contains(_ fileURL: URL, in rootURL: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        return filePath == rootPath || filePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private static func fileURL(from uri: String) -> URL? {
        guard let url = URL(string: uri), url.isFileURL else {
            return nil
        }
        return url.standardizedFileURL
    }

    private static func documentKey(_ uri: String) -> String {
        fileURL(from: uri)?.absoluteString ?? uri
    }

    private static func isGravitySource(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        return pathExtension == "ada" || pathExtension == "gravity"
    }

    private static func definition(uri: String, symbol: GravitySymbol) -> GravityDefinition {
        GravityDefinition(uri: uri, range: symbol.range, selectionRange: symbol.selectionRange)
    }

    private enum ImportResolution {
        case invalid(String)
        case source(String, Document)
        case virtual
    }
}
