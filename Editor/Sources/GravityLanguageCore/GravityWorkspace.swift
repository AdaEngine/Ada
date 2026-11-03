import AdaScriptCompilerCore
import Foundation

public final class GravityWorkspace {
    private struct Document {
        var analysis: GravityDocumentAnalysis
        var text: String
        var version: Int?
    }

    private let fileManager: FileManager
    private var hostConstructors: [GravityHostConstructor]
    private var languageService: GravityLanguageService
    private var moduleAnalysisCache: AdaScriptModuleAnalysis?
    private var projectTypeChecking: AdaScriptTypeCheckingMode = .dynamic
    private var diskDocuments: [String: Document] = [:]
    private var openDocuments: [String: Document] = [:]
    private var rootURLs: [URL] = []

    public init(
        fileManager: FileManager = .default,
        hostConstructors: [GravityHostConstructor] = []
    ) {
        self.fileManager = fileManager
        self.hostConstructors = hostConstructors
        self.languageService = GravityLanguageService(hostConstructors: hostConstructors)
    }

    public func setHostConstructors(_ constructors: [GravityHostConstructor]) {
        hostConstructors = constructors
        rebuildLanguageService()
    }

    public func setProjectTypeChecking(_ mode: AdaScriptTypeCheckingMode) {
        projectTypeChecking = mode
        rebuildLanguageService()
    }

    private func rebuildLanguageService() {
        languageService = GravityLanguageService(
            hostConstructors: hostConstructors,
            projectTypeChecking: projectTypeChecking
        )
    }

    public func configure(rootURIs: [String]) {
        rootURLs = rootURIs.compactMap(Self.fileURL(from:))
        projectTypeChecking = rootURLs.lazy.compactMap(Self.projectTypeChecking(at:)).first ?? .dynamic
        rebuildLanguageService()
        openDocuments.removeAll(keepingCapacity: true)
        moduleAnalysisCache = nil
        reloadDiskDocuments()
    }

    private static func projectTypeChecking(at rootURL: URL) -> AdaScriptTypeCheckingMode? {
        let settingsURL = rootURL.appendingPathComponent(".ada/project.json")
        guard
            let data = try? Data(contentsOf: settingsURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let build = object["build"] as? [String: Any],
            let value = build["adaScriptTypeChecking"] as? String
        else {
            return nil
        }
        return AdaScriptTypeCheckingMode(rawValue: value)
    }

    public func open(uri: String, text: String, version: Int?) {
        openDocuments[Self.documentKey(uri)] = document(text: text, version: version)
        moduleAnalysisCache = nil
    }

    public func change(uri: String, text: String, version: Int?) {
        openDocuments[Self.documentKey(uri)] = document(text: text, version: version)
        moduleAnalysisCache = nil
    }

    public func close(uri: String) {
        let key = Self.documentKey(uri)
        openDocuments.removeValue(forKey: key)
        if let url = Self.fileURL(from: uri), let text = try? String(contentsOf: url, encoding: .utf8) {
            diskDocuments[key] = document(text: text, version: nil)
        } else {
            diskDocuments.removeValue(forKey: key)
        }
        moduleAnalysisCache = nil
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
        moduleAnalysisCache = nil
    }

    public func text(for uri: String) -> String? {
        let key = Self.documentKey(uri)
        return openDocuments[key]?.text ?? diskDocuments[key]?.text
    }

    public func analysis(for uri: String) -> GravityDocumentAnalysis? {
        let key = Self.documentKey(uri)
        guard let document = openDocuments[key] ?? diskDocuments[key] else {
            return nil
        }
        var analysis = languageService.analyze(text: document.text, workspaceSymbols: workspaceSymbols(for: key))
        analysis.diagnostics += importDiagnostics(uri: key, imports: analysis.imports)
        analysis.diagnostics += moduleGraphDiagnostics(for: key, imports: analysis.imports)
        analysis.diagnostics += moduleTypeDiagnostics(for: key)
        analysis.diagnostics += AdaScriptLinter.lint(source: document.text).map { issue in
            GravityDiagnostic(message: issue.rule.message, range: issue.range.gravityRange, severity: .warning, code: issue.rule.rawValue)
        }
        var seenDiagnostics = Set<GravityDiagnostic>()
        analysis.diagnostics = analysis.diagnostics.filter { seenDiagnostics.insert($0).inserted }
        return analysis
    }

    private func moduleTypeDiagnostics(for uri: String) -> [GravityDiagnostic] {
        var documents = diskDocuments
        documents.merge(openDocuments) { _, open in open }
        let sources = documents.map { key, document in
            AdaScriptCompilerSource(path: key, source: document.text)
        }
        let module: AdaScriptModuleAnalysis
        if let moduleAnalysisCache {
            module = moduleAnalysisCache
        } else {
            module = AdaScriptAnalyzer.analyze(sources: sources)
            moduleAnalysisCache = module
        }
        guard let source = module.sources.first(where: { $0.syntax.path == uri }) else {
            return []
        }
        guard projectTypeChecking == .strict || source.syntax.isStrict else {
            return []
        }
        return source.typeIssues.map { issue in
            GravityDiagnostic(
                message: issue.message,
                range: GravitySourceRange(
                    start: GravitySourcePosition(
                        line: issue.range.start.line,
                        utf16Column: issue.range.start.utf16Column
                    ),
                    end: GravitySourcePosition(
                        line: issue.range.end.line,
                        utf16Column: issue.range.end.utf16Column
                    )
                )
            )
        }
    }

    public func completions(uri: String, position: GravitySourcePosition) -> [GravityCompletion] {
        guard let text = text(for: uri) else {
            return []
        }
        if let resource = resourceCompletionContext(text: text, position: position) {
            return resourceCompletions(context: resource)
        }
        if let imported = importNameCompletions(uri: uri, text: text, position: position) {
            return imported
        }
        return languageService.completions(
            text: text,
            position: position,
            workspaceSymbols: workspaceSymbols(for: uri)
        )
    }

    /// Names offered inside `import { | } from "module"`: a built-in module's contents, or the public
    /// declarations of the module being imported.
    private func importNameCompletions(uri: String, text: String, position: GravitySourcePosition) -> [GravityCompletion]? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.indices.contains(position.line), let caret = lines[position.line].stringIndex(atUTF16Offset: position.utf16Column) else {
            return nil
        }
        let before = (lines[..<position.line].map { $0 + "\n" }.joined()) + lines[position.line][..<caret]
        let after = String(text.dropFirst(before.count))
        guard
            let importRange = before.range(of: "import", options: .backwards),
            before[importRange.upperBound...].contains("{"),
            !before[importRange.upperBound...].contains("}"),
            !before[importRange.upperBound...].contains(";")
        else {
            return nil
        }
        // The module path follows the closing brace, possibly after the caret.
        let statementTail = after.prefix { $0 != ";" }
        guard
            let fromRange = statementTail.range(of: "from"),
            let openQuote = statementTail[fromRange.upperBound...].firstIndex(of: "\""),
            let closeQuote = statementTail[statementTail.index(after: openQuote)...].firstIndex(of: "\"")
        else {
            return nil
        }
        let modulePath = String(statementTail[statementTail.index(after: openQuote)..<closeQuote])
        var prefixStart = caret
        let line = lines[position.line]
        while prefixStart > line.startIndex, line[line.index(before: prefixStart)].isLetter || line[line.index(before: prefixStart)].isNumber || line[line.index(before: prefixStart)] == "_" {
            prefixStart = line.index(before: prefixStart)
        }
        let prefix = String(line[prefixStart..<caret])
        let range = GravitySourceRange(
            start: GravitySourcePosition(line: position.line, utf16Column: line[..<prefixStart].utf16.count),
            end: position
        )
        let names: [(name: String, detail: String, kind: GravityCompletionKind)]
        if AdaScriptModulePaths.virtualModules.contains(modulePath) {
            names = AdaScriptVirtualModules.knownNames(of: modulePath).map { ($0, "Provided by \(modulePath)", .class) }
        } else {
            let declaration = GravityImport(names: [], path: modulePath, range: range)
            guard case let .source(_, document) = resolve(declaration, from: Self.documentKey(uri)) else {
                return []
            }
            let tree = AdaScriptSyntax.parse(source: document.text, path: "")
            let hidden = Set(tree.types.filter { $0.visibility == .private }.map(\.name)
                + tree.functions.filter { $0.visibility == .private }.map(\.name)
                + tree.bindings.filter { $0.visibility == .private }.map(\.name))
            names = document.analysis.symbols
                .filter { !hidden.contains($0.name) }
                .map { ($0.name, $0.detail, GravityCompletionCandidate(symbol: $0).kind) }
        }
        return names
            .filter { prefix.isEmpty || $0.name.localizedCaseInsensitiveContains(prefix) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map {
                GravityCompletion(label: $0.name, detail: $0.detail, insertText: $0.name, kind: $0.kind, replacementRange: range, sortText: "00")
            }
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
        if AdaScriptModulePaths.virtualModules.contains(scriptImport.path) {
            return .virtual
        }
        guard let importerURL = Self.fileURL(from: importerURI) else {
            return .invalid("Unable to resolve import from a non-file document")
        }
        guard let root = moduleRoot(containing: importerURL) else {
            return .invalid("Import escapes the configured AdaScript workspace")
        }
        let importerPath = String(importerURL.path.dropFirst(root.path.count).drop(while: { $0 == "/" }))
        let resolved: AdaScriptModulePaths.ResolvedImport
        do {
            resolved = try AdaScriptModulePaths.resolveImport(scriptImport.path, from: importerPath)
        } catch {
            switch error {
            case .invalidSourcePath:
                return .invalid("Import escapes the configured AdaScript workspace")
            case let .invalidImport(_, message):
                return .invalid(message.prefix(1).uppercased() + message.dropFirst())
            default:
                return .invalid("Unable to resolve import '\(scriptImport.path)'")
            }
        }
        switch resolved {
        case .virtual:
            return .virtual
        case let .source(path):
            let importedURL = path.hasPrefix("Libraries/") ? libraryURL(for: path) : root.appendingPathComponent(path).standardizedFileURL
            guard let importedURL else {
                return .invalid("Unable to resolve import '\(scriptImport.path)'")
            }
            let importedURI = importedURL.absoluteString
            guard let document = openDocuments[importedURI] ?? diskDocuments[importedURI] else {
                return .invalid("Unable to resolve import '\(scriptImport.path)'")
            }
            return .source(importedURI, document)
        }
    }

    /// The directory imports resolve against: the project's configured source root when the importer
    /// is inside it (the runtime's rule), otherwise the workspace root containing the importer.
    private func moduleRoot(containing url: URL) -> URL? {
        for root in rootURLs where Self.contains(url, in: root) {
            if let sources = Self.sourceRoot(at: root), Self.contains(url, in: sources) {
                return sources
            }
            return root.standardizedFileURL
        }
        return nil
    }

    /// Locates a `Libraries/<id>/<path>` import among the restored library sources.
    private func libraryURL(for path: String) -> URL? {
        let components = path.split(separator: "/")
        guard components.count >= 3 else { return nil }
        let identifier = String(components[1])
        let relative = components.dropFirst(2).joined(separator: "/")
        let documents = diskDocuments.keys.sorted()
        return documents.compactMap { key -> URL? in
            guard key.contains("/.ada/libraries/"), key.hasSuffix("/" + relative),
                key.components(separatedBy: "/.ada/libraries/").last?.hasPrefix(identifier) == true
            else { return nil }
            return URL(string: key)
        }.first
    }

    private static func sourceRoot(at rootURL: URL) -> URL? {
        guard
            let data = try? Data(contentsOf: rootURL.appendingPathComponent(".ada/project.json")),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let paths = object["paths"] as? [String: Any],
            let sources = paths["sources"] as? String,
            !sources.isEmpty
        else {
            return nil
        }
        return rootURL.appendingPathComponent(sources, isDirectory: true).standardizedFileURL
    }

    /// Cycle and visibility findings for one document, computed from the whole workspace with the same
    /// rules the runtime applies.
    private func moduleGraphDiagnostics(for uri: String, imports: [GravityImport]) -> [GravityDiagnostic] {
        var diagnostics = cycleDiagnostics(for: uri, imports: imports)
        diagnostics += visibilityDiagnostics(for: uri)
        return diagnostics
    }

    private func cycleDiagnostics(for uri: String, imports: [GravityImport]) -> [GravityDiagnostic] {
        var documents = diskDocuments
        documents.merge(openDocuments) { _, open in open }
        var edges: [String: [String]] = [:]
        for (key, document) in documents {
            edges[key] = document.analysis.imports.compactMap { scriptImport in
                guard case let .source(importedURI, _) = resolve(scriptImport, from: key) else { return nil }
                return importedURI
            }
        }
        var diagnostics: [GravityDiagnostic] = []
        for cycle in AdaScriptModuleOrdering.cycles(edges: edges) {
            let members = cycle.dropLast()
            guard let position = members.firstIndex(of: uri) else { continue }
            let next = cycle[position + 1]
            let display = cycle.map { Self.displayName($0) }.joined(separator: " -> ")
            for scriptImport in imports {
                guard case let .source(importedURI, _) = resolve(scriptImport, from: uri), importedURI == next else { continue }
                diagnostics.append(GravityDiagnostic(message: "Import cycle: \(display)", range: scriptImport.range))
            }
        }
        return diagnostics
    }

    private func visibilityDiagnostics(for uri: String) -> [GravityDiagnostic] {
        var documents = diskDocuments
        documents.merge(openDocuments) { _, open in open }
        guard
            let importerURL = Self.fileURL(from: uri), let root = moduleRoot(containing: importerURL),
            documents[uri] != nil
        else {
            return []
        }
        func modulePath(_ key: String) -> String? {
            guard let url = Self.fileURL(from: key), Self.contains(url, in: root) else { return nil }
            return String(url.path.dropFirst(root.path.count).drop(while: { $0 == "/" }))
        }
        var sources: [AdaScriptCompilerSource] = []
        for (key, document) in documents.sorted(by: { $0.key < $1.key }) {
            guard let path = modulePath(key), let canonical = try? AdaScriptModulePaths.canonicalSourcePath(path) else { continue }
            sources.append(AdaScriptCompilerSource(path: canonical, source: document.text))
        }
        guard let ownPath = modulePath(uri), let graph = try? AdaScriptModuleGraph(sources: sources) else { return [] }
        // Only the importer's own dependency closure counts for duplicate names: unrelated files in the
        // workspace never share a Gravity scope.
        var scope: Set<String> = [ownPath]
        var pending = [ownPath]
        while let current = pending.popLast() {
            for dependency in (try? graph.dependencies(of: current)) ?? [] where scope.insert(dependency).inserted {
                pending.append(dependency)
            }
        }
        return graph.semanticDiagnostics(scope: scope)
            .filter { $0.path == ownPath }
            .map { GravityDiagnostic(message: $0.message, range: $0.range.gravityRange) }
    }

    private static func displayName(_ uri: String) -> String {
        fileURL(from: uri)?.lastPathComponent ?? uri
    }

    private func document(text: String, version: Int?) -> Document {
        Document(analysis: GravityDocumentAnalyzer.parse(text).analysis, text: text, version: version)
    }

    private func reloadDiskDocuments() {
        diskDocuments.removeAll(keepingCapacity: true)
        moduleAnalysisCache = nil
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
