public struct AdaScriptSourcePosition: Equatable, Hashable, Sendable {
    public var line: Int
    public var utf16Column: Int

    public init(line: Int, utf16Column: Int) {
        self.line = line
        self.utf16Column = utf16Column
    }
}

public struct AdaScriptSourceRange: Equatable, Hashable, Sendable {
    public var start: AdaScriptSourcePosition
    public var end: AdaScriptSourcePosition

    public init(start: AdaScriptSourcePosition, end: AdaScriptSourcePosition) {
        self.start = start
        self.end = end
    }
}

/// A type known by AdaScript's static analysis layer. `unknown` means the
/// analyzer could not prove a type, while `any` is an explicit dynamic boundary.
public indirect enum AdaScriptType: Equatable, Hashable, Sendable {
    case any
    case bool
    case float
    case int
    case list(Self)
    case map(key: Self, value: Self)
    case named(String)
    case null
    case query([String])
    case queryRow([String])
    case string
    case unknown
    case void

    public init(spelling: String) {
        switch spelling.lowercased() {
        case "any", "dynamic", "variant":
            self = .any
        case "bool", "boolean":
            self = .bool
        case "float", "double", "number":
            self = .float
        case "int", "integer":
            self = .int
        case "null":
            self = .null
        case "string":
            self = .string
        case "void":
            self = .void
        default:
            self = .named(spelling)
        }
    }

    public var displayName: String {
        switch self {
        case .any: "Any"
        case .bool: "Bool"
        case .float: "Float"
        case .int: "Int"
        case let .list(element): "List<\(element.displayName)>"
        case let .map(key, value): "Map<\(key.displayName), \(value.displayName)>"
        case let .named(name): name
        case .null: "Null"
        case .query: "$AdaQueryCollection"
        case .queryRow: "$AdaEntity"
        case .string: "String"
        case .unknown: "Unknown"
        case .void: "Void"
        }
    }

    public func accepts(_ value: Self) -> Bool {
        if self == .any || self == .unknown || value == .any || value == .unknown {
            return true
        }
        if self == value {
            return true
        }
        if self == .float, value == .int {
            return true
        }
        if value == .null {
            return true
        }
        return switch (self, value) {
        case let (.list(expected), .list(actual)):
            expected.accepts(actual)
        case let (.map(expectedKey, expectedValue), .map(actualKey, actualValue)):
            expectedKey.accepts(actualKey) && expectedValue.accepts(actualValue)
        default:
            false
        }
    }
}

public struct AdaScriptAnnotationSyntax: Equatable, Hashable, Sendable {
    public var arguments: [String]
    public var name: String
    public var range: AdaScriptSourceRange

    public init(arguments: [String] = [], name: String, range: AdaScriptSourceRange) {
        self.arguments = arguments
        self.name = name
        self.range = range
    }
}

public struct AdaScriptBindingSyntax: Equatable, Hashable, Sendable {
    public var annotations: [AdaScriptAnnotationSyntax]
    public var declaredType: AdaScriptType?
    public var isConstant: Bool
    public var name: String
    public var range: AdaScriptSourceRange

    public init(
        annotations: [AdaScriptAnnotationSyntax] = [],
        declaredType: AdaScriptType? = nil,
        isConstant: Bool,
        name: String,
        range: AdaScriptSourceRange
    ) {
        self.annotations = annotations
        self.declaredType = declaredType
        self.isConstant = isConstant
        self.name = name
        self.range = range
    }
}

public struct AdaScriptParameterSyntax: Equatable, Hashable, Sendable {
    public var declaredType: AdaScriptType?
    public var hasDefaultValue: Bool
    public var name: String
    public var range: AdaScriptSourceRange

    public init(declaredType: AdaScriptType? = nil, hasDefaultValue: Bool = false, name: String, range: AdaScriptSourceRange) {
        self.declaredType = declaredType
        self.hasDefaultValue = hasDefaultValue
        self.name = name
        self.range = range
    }
}

public struct AdaScriptFunctionSyntax: Equatable, Hashable, Sendable {
    public var annotations: [AdaScriptAnnotationSyntax]
    public var isAsync: Bool
    public var name: String
    public var parameters: [AdaScriptParameterSyntax]
    public var range: AdaScriptSourceRange
    public var returnType: AdaScriptType?

    public init(
        annotations: [AdaScriptAnnotationSyntax] = [],
        isAsync: Bool,
        name: String,
        parameters: [AdaScriptParameterSyntax],
        range: AdaScriptSourceRange,
        returnType: AdaScriptType? = nil
    ) {
        self.annotations = annotations
        self.isAsync = isAsync
        self.name = name
        self.parameters = parameters
        self.range = range
        self.returnType = returnType
    }
}

public struct AdaScriptTypeSyntax: Equatable, Hashable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable {
        case `class`
        case `enum`
        case `struct`
    }

    public var annotations: [AdaScriptAnnotationSyntax]
    public var bindings: [AdaScriptBindingSyntax]
    public var functions: [AdaScriptFunctionSyntax]
    public var kind: Kind
    public var name: String
    public var range: AdaScriptSourceRange

    public init(
        annotations: [AdaScriptAnnotationSyntax] = [],
        bindings: [AdaScriptBindingSyntax] = [],
        functions: [AdaScriptFunctionSyntax] = [],
        kind: Kind,
        name: String,
        range: AdaScriptSourceRange
    ) {
        self.annotations = annotations
        self.bindings = bindings
        self.functions = functions
        self.kind = kind
        self.name = name
        self.range = range
    }
}

public struct AdaScriptSyntaxTree: Equatable, Sendable {
    public var bindings: [AdaScriptBindingSyntax]
    public var functions: [AdaScriptFunctionSyntax]
    public var isStrict: Bool
    public var path: String
    public var types: [AdaScriptTypeSyntax]

    public init(
        bindings: [AdaScriptBindingSyntax] = [],
        functions: [AdaScriptFunctionSyntax] = [],
        isStrict: Bool = false,
        path: String,
        types: [AdaScriptTypeSyntax] = []
    ) {
        self.bindings = bindings
        self.functions = functions
        self.isStrict = isStrict
        self.path = path
        self.types = types
    }
}

public enum AdaScriptTypeCheckingMode: String, Codable, Equatable, Hashable, Sendable {
    case dynamic
    case strict
}

public struct AdaScriptCallableType: Equatable, Hashable, Sendable {
    public var parameters: [AdaScriptType]
    public var returnType: AdaScriptType

    public init(parameters: [AdaScriptType], returnType: AdaScriptType = .unknown) {
        self.parameters = parameters
        self.returnType = returnType
    }
}

public enum AdaScriptMemberKind: Equatable, Hashable, Sendable {
    case method
    case property
}

public struct AdaScriptMemberType: Equatable, Hashable, Sendable {
    public var callable: AdaScriptCallableType?
    public var detail: String?
    public var insertText: String?
    public var kind: AdaScriptMemberKind
    public var type: AdaScriptType

    public init(
        type: AdaScriptType,
        callable: AdaScriptCallableType? = nil,
        detail: String? = nil,
        insertText: String? = nil,
        kind: AdaScriptMemberKind = .property
    ) {
        self.callable = callable
        self.detail = detail
        self.insertText = insertText
        self.kind = kind
        self.type = type
    }
}

/// External types visible to the analyzer. Runtime and editor integrations can
/// extend this catalog without coupling the compiler core to engine modules.
public struct AdaScriptTypeEnvironment: Equatable, Sendable {
    public var functions: [String: AdaScriptCallableType]
    public var members: [String: [String: AdaScriptMemberType]]
    public var values: [String: AdaScriptType]

    public init(
        functions: [String: AdaScriptCallableType] = [:],
        members: [String: [String: AdaScriptMemberType]] = [:],
        values: [String: AdaScriptType] = [:]
    ) {
        self.functions = functions
        self.members = members
        self.values = values
    }

    public mutating func register(schemas: [AdaScriptDataSchema]) {
        for schema in schemas {
            var schemaMembers = Dictionary(uniqueKeysWithValues: schema.fields.map { field in
                (field.name, AdaScriptMemberType(type: field.defaultValue.analysisType))
            })
            if case .resource = schema.kind {
                schemaMembers["available"] = AdaScriptMemberType(
                    type: .bool,
                    callable: AdaScriptCallableType(parameters: [], returnType: .bool),
                    detail: "available() -> Bool — whether an optional resource is bound",
                    insertText: "available()",
                    kind: .method
                )
            }
            members[schema.name] = schemaMembers
        }
    }
}

public struct AdaScriptTypeIssue: Equatable, Hashable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable {
        case argumentType
        case assignmentType
        case memberAccess
        case returnType
    }

    public var kind: Kind
    public var message: String
    public var path: String
    public var range: AdaScriptSourceRange

    public init(kind: Kind, message: String, path: String, range: AdaScriptSourceRange) {
        self.kind = kind
        self.message = message
        self.path = path
        self.range = range
    }
}

public struct AdaScriptSourceAnalysis: Equatable, Sendable {
    public var inferredTypes: [String: AdaScriptType]
    public var syntax: AdaScriptSyntaxTree
    public var typeIssues: [AdaScriptTypeIssue]

    public init(
        inferredTypes: [String: AdaScriptType] = [:],
        syntax: AdaScriptSyntaxTree,
        typeIssues: [AdaScriptTypeIssue] = []
    ) {
        self.inferredTypes = inferredTypes
        self.syntax = syntax
        self.typeIssues = typeIssues
    }
}

public struct AdaScriptModuleAnalysis: Equatable, Sendable {
    public var sources: [AdaScriptSourceAnalysis]

    public init(sources: [AdaScriptSourceAnalysis]) {
        self.sources = sources
    }

    public var typeIssues: [AdaScriptTypeIssue] {
        sources.flatMap(\.typeIssues)
    }

    public func enforcedTypeIssues(mode: AdaScriptTypeCheckingMode) -> [AdaScriptTypeIssue] {
        sources.flatMap { source in
            mode == .strict || source.syntax.isStrict ? source.typeIssues : []
        }
    }

    public func requireValidTypes(mode: AdaScriptTypeCheckingMode) throws {
        let issues = enforcedTypeIssues(mode: mode)
        guard issues.isEmpty else {
            throw AdaScriptTypeCheckingError(issues: issues)
        }
    }
}

public struct AdaScriptTypeCheckingError: Error, Equatable, Sendable, CustomStringConvertible {
    public var issues: [AdaScriptTypeIssue]

    public init(issues: [AdaScriptTypeIssue]) {
        self.issues = issues
    }

    public var description: String {
        issues.map { issue in
            "\(issue.path):\(issue.range.start.line + 1):\(issue.range.start.utf16Column + 1): \(issue.message)"
        }
        .joined(separator: "\n")
    }
}

private extension AdaScriptSchemaField.Value {
    var analysisType: AdaScriptType {
        switch self {
        case .bool: .bool
        case .double: .float
        case .int: .int
        case .string: .string
        }
    }
}
