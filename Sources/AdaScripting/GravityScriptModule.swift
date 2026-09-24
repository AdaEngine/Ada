import AdaScriptCompilerCore
import Foundation

public enum AdaScriptError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case compilation([String])
    case duplicateSourcePath(String)
    case importCycle([String])
    case invalidImport(source: String, message: String)
    case invalidManifest(String)
    case invalidSourcePath(String)
    case unknownComponent(system: String, queryIndex: Int, component: String)
    case unknownResource(system: String, resource: String)
    case unresolvedImport(source: String, importPath: String)

    public var description: String {
        switch self {
        case let .compilation(diagnostics):
            diagnostics.joined(separator: "\n")
        case let .duplicateSourcePath(path):
            "Duplicate Ada Script source path '\(path)'"
        case let .importCycle(paths):
            "Ada Script import cycle: \(paths.joined(separator: " -> "))"
        case let .invalidImport(source, message):
            "Invalid Ada Script import in '\(source)': \(message)"
        case let .invalidManifest(message):
            "Invalid Ada Script annotations: \(message)"
        case let .invalidSourcePath(path):
            "Invalid Ada Script source path '\(path)'"
        case let .unknownComponent(system, queryIndex, component):
            "Unknown component '\(component)' in query \(queryIndex) of system '\(system)'"
        case let .unknownResource(system, resource):
            "Unknown resource '\(resource)' in system '\(system)'"
        case let .unresolvedImport(source, importPath):
            "Unable to resolve Ada Script import '\(importPath)' from '\(source)'"
        }
    }

    public var errorDescription: String? { description }
}

/// One source file embedded in an Ada Script module.
public typealias AdaScriptSource = AdaScriptCompilerSource

struct ResolvedGravityScriptModule: Sendable {
    struct Source: Sendable {
        let fileID: UInt32
        let source: String
    }

    let entrySource: String
    let sourcesByPath: [String: Source]
    let pathsByFileID: [UInt32: String]
    let nonSendableTypeNames: Set<String>
    let asyncDeclarations: [AdaScriptAsyncDeclaration]

    func requireSynchronousCallback(className: String, method: String, annotation: String) throws {
        guard let declaration = asyncDeclarations.first(where: { $0.ownerType == className && $0.name == method }) else {
            return
        }
        throw AdaScriptError.invalidManifest(
            "\(annotation) callback '\(className).\(method)' at line \(declaration.line) cannot be async"
        )
    }
}

enum GravityScriptModuleResolver {
    static func resolve(_ sources: [AdaScriptSource]) throws -> ResolvedGravityScriptModule {
        var sourceByPath: [String: AdaScriptSource] = [:]
        var preliminarySources: [String: ParsedSource] = [:]
        for source in sources {
            let path = try canonicalSourcePath(source.path)
            guard sourceByPath[path] == nil else {
                throw AdaScriptError.duplicateSourcePath(path)
            }
            sourceByPath[path] = source
            var scanner = AdaScriptSourceScanner(source: source.source, path: path)
            preliminarySources[path] = try scanner.scan()
        }

        let sortedPaths = sourceByPath.keys.sorted()
        let compilerSources = sortedPaths.compactMap { sourceByPath[$0] }
        let schemas = try AdaScriptSchemaParser.parse(sources: compilerSources)
        var analysisEnvironment = AdaScriptTypeEnvironment.standard
        analysisEnvironment.register(schemas: schemas)
        let analysis = AdaScriptAnalyzer.analyze(sources: compilerSources, environment: analysisEnvironment)
        do {
            try analysis.requireValidTypes(mode: .dynamic)
        } catch let error as AdaScriptTypeCheckingError {
            throw AdaScriptError.compilation(error.description.components(separatedBy: "\n"))
        }
        let discoveryRoots = sortedPaths.filter { path in
            guard let annotations = preliminarySources[path]?.annotations else {
                return false
            }
            return !annotations.isDisjoint(with: rootAnnotations)
        }
        let roots = discoveryRoots.isEmpty ? sortedPaths : discoveryRoots

        var states: [String: VisitState] = [:]
        var stack: [String] = []
        var orderedPaths: [String] = []
        for root in roots {
            try visit(
                root,
                parsedSources: preliminarySources,
                states: &states,
                stack: &stack,
                orderedPaths: &orderedPaths
            )
        }

        var nonSendableTypeNames = Set<String>()
        for path in orderedPaths {
            guard let source = sourceByPath[path] else {
                continue
            }
            do {
                nonSendableTypeNames.formUnion(try AdaScriptNonSendableTypes.declared(in: source.source, path: path))
            } catch let error as AdaScriptAsyncSyntaxError {
                throw AdaScriptError.invalidManifest(error.description)
            }
        }

        var asyncDeclarations: [AdaScriptAsyncDeclaration] = []
        for path in orderedPaths {
            guard let source = sourceByPath[path] else {
                continue
            }
            do {
                let declarations = try AdaScriptAsyncDeclarationScanner.declarations(
                    in: source.source,
                    path: path,
                    nonSendableTypes: nonSendableTypeNames
                )
                asyncDeclarations += declarations
            } catch let error as AdaScriptAsyncSyntaxError {
                throw AdaScriptError.invalidManifest(error.description)
            }
        }

        var parsedSources: [String: ParsedSource] = [:]
        for path in sortedPaths {
            guard let source = sourceByPath[path] else {
                continue
            }
            let loweredViewSource: String
            do {
                loweredViewSource = try AdaScriptViewBuilderLowerer.lower(
                    source: AdaScriptTypeAnnotationLowerer.lower(source: source.source),
                    path: path
                )
            } catch let error as AdaScriptViewBuilderError {
                throw AdaScriptError.invalidManifest(error.description)
            }
            let loweredAssetsSource = AdaScriptAssetsLowerer.lower(source: loweredViewSource)
            let schemas = try AdaScriptSchemaParser.parse(sources: [source])
            let loweredComponentSource = AdaScriptComponentLowerer.lower(
                source: loweredAssetsSource,
                schemas: schemas
            )
            let loweredSource = AdaScriptMathLowerer.lower(
                source: AdaScriptNetworkLowerer.lower(source: loweredComponentSource)
            )
            var scanner = AdaScriptSourceScanner(source: loweredSource, path: path)
            parsedSources[path] = try scanner.scan()
        }

        var sourcesByPath: [String: ResolvedGravityScriptModule.Source] = [:]
        var pathsByFileID: [UInt32: String] = [:]
        for (offset, path) in sortedPaths.enumerated() {
            guard let source = parsedSources[path] else {
                continue
            }
            let fileID = UInt32(offset + 1)
            sourcesByPath[path] = .init(fileID: fileID, source: source.sanitizedSource)
            pathsByFileID[fileID] = path
        }

        let includes =
            orderedPaths
            .map { path in "#include \"\(escapeGravityString(path))\"" }
            .joined(separator: "\n")
        let entrySource = """
        extern var adaUIBuilder;
        extern var __adaAssets;
        \(includes)
        """

        return ResolvedGravityScriptModule(
            entrySource: entrySource,
            sourcesByPath: sourcesByPath,
            pathsByFileID: pathsByFileID,
            nonSendableTypeNames: nonSendableTypeNames,
            asyncDeclarations: asyncDeclarations
        )
    }

    private static let rootAnnotations: Set<String> = [
        "component",
        "network_command",
        "rpc",
        "replicated_component",
        "resource",
        "scriptable",
        "system",
        "view",
    ]

    private static func visit(
        _ path: String,
        parsedSources: [String: ParsedSource],
        states: inout [String: VisitState],
        stack: inout [String],
        orderedPaths: inout [String]
    ) throws {
        switch states[path] {
        case .visited:
            return
        case .visiting:
            guard let cycleStart = stack.firstIndex(of: path) else {
                throw AdaScriptError.importCycle(stack + [path])
            }
            throw AdaScriptError.importCycle(Array(stack[cycleStart...]) + [path])
        case nil:
            break
        }

        guard let source = parsedSources[path] else {
            return
        }
        states[path] = .visiting
        stack.append(path)
        defer { _ = stack.popLast() }

        for importPath in source.imports {
            if virtualModules.contains(importPath) {
                continue
            }
            let resolvedPath = try resolveImport(importPath, from: path)
            guard parsedSources[resolvedPath] != nil else {
                throw AdaScriptError.unresolvedImport(source: path, importPath: importPath)
            }
            try visit(
                resolvedPath,
                parsedSources: parsedSources,
                states: &states,
                stack: &stack,
                orderedPaths: &orderedPaths
            )
        }

        states[path] = .visited
        orderedPaths.append(path)
    }

    private static let virtualModules: Set<String> = ["AdaEngine", "AdaUI"]

    private static func canonicalSourcePath(_ path: String) throws -> String {
        try canonicalPath(path, baseComponents: [])
    }

    private static func resolveImport(_ importPath: String, from sourcePath: String) throws -> String {
        if importPath.hasPrefix("@") {
            let parts = importPath.dropFirst().split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, AdaScriptLibraryManifest.isIdentifier(String(parts[0])) else {
                throw AdaScriptError.invalidImport(source: sourcePath, message: "library imports use @library.id/path")
            }
            var path = String(parts[1])
            if URL(fileURLWithPath: path).pathExtension.isEmpty {
                path += ".ada"
            }
            guard AdaScriptLibraryManifest.isSourcePath(path) else {
                throw AdaScriptError.invalidImport(source: sourcePath, message: "invalid library source path")
            }
            return "Libraries/\(parts[0])/\(path)"
        }
        guard importPath.hasPrefix("./") || importPath.hasPrefix("../") else {
            throw AdaScriptError.invalidImport(
                source: sourcePath,
                message: "imports must be relative or name a supported virtual module: '\(importPath)'"
            )
        }
        var baseComponents = sourcePath.split(separator: "/").map(String.init)
        _ = baseComponents.popLast()
        var resolved = try canonicalPath(importPath, baseComponents: baseComponents)
        if URL(fileURLWithPath: resolved).pathExtension.isEmpty {
            resolved += ".ada"
        }
        return resolved
    }

    private static func canonicalPath(_ path: String, baseComponents: [String]) throws -> String {
        let normalizedSeparators = path.replacingOccurrences(of: "\\", with: "/")
        guard
            !normalizedSeparators.isEmpty,
            !normalizedSeparators.hasPrefix("/"),
            !isWindowsAbsolutePath(normalizedSeparators),
            !normalizedSeparators.contains("\"")
        else {
            throw AdaScriptError.invalidSourcePath(path)
        }

        var components = baseComponents
        for component in normalizedSeparators.split(separator: "/", omittingEmptySubsequences: false) {
            switch component {
            case "",
                ".":
                continue
            case "..":
                guard !components.isEmpty else {
                    throw AdaScriptError.invalidSourcePath(path)
                }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }
        guard !components.isEmpty else {
            throw AdaScriptError.invalidSourcePath(path)
        }
        return components.joined(separator: "/")
    }

    private static func isWindowsAbsolutePath(_ path: String) -> Bool {
        let scalars = Array(path.unicodeScalars)
        return scalars.count >= 2 && scalars[1] == ":"
    }

    private static func escapeGravityString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private enum VisitState {
        case visiting
        case visited
    }
}

private struct ParsedSource {
    let annotations: Set<String>
    let imports: [String]
    let sanitizedSource: String
}

private struct AdaScriptSourceScanner {
    private let source: String
    private let path: String
    private var index: String.Index

    init(source: String, path: String) {
        self.source = source
        self.path = path
        self.index = source.startIndex
    }

    mutating func scan() throws -> ParsedSource {
        var annotations = Set<String>()
        var imports: [(path: String, range: Range<String.Index>)] = []

        while index < source.endIndex {
            if try skipTrivia() {
                continue
            }
            if source[index] == "\"" {
                _ = try parseStringLiteral()
                continue
            }
            if source[index] == "@" {
                advance()
                if let annotation = parseIdentifier() {
                    annotations.insert(annotation)
                }
                continue
            }
            if consumeKeyword("import") {
                imports.append(try parseImport(start: source.index(index, offsetBy: -"import".count)))
                continue
            }
            advance()
        }

        var sanitizedSource = source
        for item in imports.reversed() {
            let replacement = source[item.range]
                .map { character in
                    character == "\n" || character == "\r" ? character : " "
                }
            sanitizedSource.replaceSubrange(item.range, with: replacement)
        }
        return ParsedSource(
            annotations: annotations,
            imports: imports.map(\.path),
            sanitizedSource: sanitizedSource
        )
    }

    private mutating func parseImport(start: String.Index) throws -> (path: String, range: Range<String.Index>) {
        try requireTrivia()
        if consume("{") {
            try skipImportList()
        } else if consume("*") {
            throw invalidImport("namespace imports are not implemented yet")
        } else {
            throw invalidImport("expected '{ ... }' or '* as Alias'")
        }

        try requireTrivia()
        try requireKeyword("from")
        try requireTrivia()
        guard index < source.endIndex, source[index] == "\"" else {
            throw invalidImport("expected quoted module path")
        }
        let importPath = try parseStringLiteral()
        _ = try skipTrivia()
        guard consume(";") else {
            throw invalidImport("expected ';' after import")
        }
        return (path: importPath, range: start..<index)
    }

    private mutating func skipImportList() throws {
        var expectsIdentifier = true
        var hasIdentifier = false
        while index < source.endIndex {
            if try skipTrivia() {
                continue
            }
            if consume("}") {
                guard hasIdentifier, !expectsIdentifier else {
                    throw invalidImport("expected imported identifier before '}'")
                }
                return
            }
            if expectsIdentifier {
                guard parseIdentifier() != nil else {
                    throw invalidImport("expected imported identifier")
                }
                hasIdentifier = true
                expectsIdentifier = false
            } else {
                guard consume(",") else {
                    throw invalidImport("expected ',' or '}'")
                }
                expectsIdentifier = true
            }
        }
        throw invalidImport("unterminated import list")
    }

    @discardableResult
    private mutating func skipTrivia() throws -> Bool {
        var skipped = false
        while index < source.endIndex {
            if source[index].isWhitespace {
                skipped = true
                advance()
                continue
            }
            if hasPrefix("//") {
                skipped = true
                while index < source.endIndex, source[index] != "\n" { advance() }
                continue
            }
            if hasPrefix("/*") {
                skipped = true
                advance(2)
                while index < source.endIndex, !hasPrefix("*/") { advance() }
                guard index < source.endIndex else {
                    throw invalidImport("unterminated block comment")
                }
                advance(2)
                continue
            }
            break
        }
        return skipped
    }

    private mutating func requireTrivia() throws {
        _ = try skipTrivia()
    }

    private mutating func parseStringLiteral() throws -> String {
        guard consume("\"") else {
            throw invalidImport("expected string literal")
        }
        var result = ""
        while index < source.endIndex {
            let character = source[index]
            advance()
            if character == "\"" {
                return result
            }
            if character == "\\" {
                guard index < source.endIndex else {
                    throw invalidImport("unterminated string escape")
                }
                result.append(source[index])
                advance()
            } else {
                result.append(character)
            }
        }
        throw invalidImport("unterminated string literal")
    }

    private mutating func requireKeyword(_ keyword: String) throws {
        guard consumeKeyword(keyword) else {
            throw invalidImport("expected '\(keyword)'")
        }
    }

    private mutating func consumeKeyword(_ keyword: String) -> Bool {
        guard hasPrefix(keyword) else {
            return false
        }
        let end = source.index(index, offsetBy: keyword.count)
        if index > source.startIndex {
            let previous = source[source.index(before: index)]
            guard !isIdentifierCharacter(previous) else {
                return false
            }
        }
        if end < source.endIndex {
            guard !isIdentifierCharacter(source[end]) else {
                return false
            }
        }
        index = end
        return true
    }

    private mutating func parseIdentifier() -> String? {
        guard index < source.endIndex, isIdentifierStart(source[index]) else {
            return nil
        }
        let start = index
        advance()
        while index < source.endIndex, isIdentifierCharacter(source[index]) { advance() }
        return String(source[start..<index])
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private func isIdentifierCharacter(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }

    private mutating func consume(_ literal: Character) -> Bool {
        guard index < source.endIndex, source[index] == literal else {
            return false
        }
        advance()
        return true
    }

    private func hasPrefix(_ prefix: String) -> Bool {
        source[index...].hasPrefix(prefix)
    }

    private mutating func advance(_ distance: Int = 1) {
        index = source.index(index, offsetBy: distance, limitedBy: source.endIndex) ?? source.endIndex
    }

    private func invalidImport(_ message: String) -> AdaScriptError {
        .invalidImport(source: path, message: message)
    }
}
