public enum AdaScriptSchemaParser {
    public static func parse(sources: [AdaScriptCompilerSource]) throws -> [AdaScriptDataSchema] {
        var schemas: [AdaScriptDataSchema] = []
        for source in sources.sorted(by: { $0.path < $1.path }) {
            var parser = Parser(source: source.source, path: source.path)
            schemas += try parser.parse().schemas
        }

        var ids = Set<String>()
        var names = Set<String>()
        for schema in schemas {
            guard ids.insert(schema.id).inserted else {
                throw AdaScriptSchemaError.duplicateID(schema.id)
            }
            guard names.insert(schema.name).inserted else {
                throw AdaScriptSchemaError.duplicateName(schema.name)
            }
        }
        return schemas
    }

    public static func parseResourceBindings(sources: [AdaScriptCompilerSource]) throws -> [AdaScriptResourceBinding] {
        var bindings: [AdaScriptResourceBinding] = []
        for source in sources.sorted(by: { $0.path < $1.path }) {
            var parser = Parser(source: source.source, path: source.path)
            bindings += try parser.parse().resourceBindings
        }
        return bindings
    }

    public static func parseScriptables(sources: [AdaScriptCompilerSource]) throws -> [AdaScriptableSchema] {
        var schemas: [AdaScriptableSchema] = []
        for source in sources.sorted(by: { $0.path < $1.path }) {
            var parser = Parser(source: source.source, path: source.path)
            schemas += try parser.parse().scriptables
        }

        var ids = Set<String>()
        var names = Set<String>()
        for schema in schemas {
            guard ids.insert(schema.id).inserted else {
                throw AdaScriptSchemaError.duplicateID(schema.id)
            }
            guard names.insert(schema.name).inserted else {
                throw AdaScriptSchemaError.duplicateName(schema.name)
            }
        }
        return schemas
    }

    public static func parseSystemCapabilities(sources: [AdaScriptCompilerSource]) throws -> [AdaScriptSystemCapabilities] {
        var capabilities: [AdaScriptSystemCapabilities] = []
        for source in sources.sorted(by: { $0.path < $1.path }) {
            var parser = Parser(source: source.source, path: source.path)
            capabilities += try parser.parse().systemCapabilities
        }
        return capabilities
    }

    public static func parseTools(sources: [AdaScriptCompilerSource]) throws -> [AdaScriptToolSchema] {
        var schemas: [AdaScriptToolSchema] = []
        for source in sources.sorted(by: { $0.path < $1.path }) {
            var parser = Parser(source: source.source, path: source.path)
            schemas += try parser.parse().tools
        }

        var ids = Set<String>()
        for schema in schemas {
            guard ids.insert(schema.id).inserted else {
                throw AdaScriptSchemaError.duplicateToolID(schema.id)
            }
        }
        return schemas
    }

    public static func parseViews(sources: [AdaScriptCompilerSource]) throws -> [AdaScriptViewSchema] {
        var schemas: [AdaScriptViewSchema] = []
        for source in sources.sorted(by: { $0.path < $1.path }) {
            var parser = Parser(source: source.source, path: source.path)
            schemas += try parser.parse().views
        }

        var ids = Set<String>()
        var names = Set<String>()
        for schema in schemas {
            guard ids.insert(schema.id).inserted else {
                throw AdaScriptSchemaError.duplicateID(schema.id)
            }
            guard names.insert(schema.className).inserted else {
                throw AdaScriptSchemaError.duplicateName(schema.className)
            }
        }
        return schemas
    }
}

struct Annotation {
    let arguments: [String: Literal]
    let name: String
    let positionalArguments: [Literal]

    func previewTitle(viewName: String, path: String) throws -> String? {
        guard arguments.keys.allSatisfy({ $0 == "title" }) else {
            throw AdaScriptSchemaError.invalid(path: path, message: "@previewable on \(viewName) only supports title")
        }
        let titleCount = positionalArguments.count + (arguments["title"] == nil ? 0 : 1)
        guard titleCount <= 1 else {
            throw AdaScriptSchemaError.invalid(path: path, message: "@previewable on \(viewName) accepts one title")
        }
        guard let literal = arguments["title"] ?? positionalArguments.first else {
            return nil
        }
        guard case let .string(title) = literal else {
            throw AdaScriptSchemaError.invalid(path: path, message: "@previewable title on \(viewName) must be a string")
        }
        return title
    }
}

enum Literal {
    case bool(Bool)
    case identifier(String)
    case list([Self])
    case number(String)
    case string(String)
}

struct Token {
    enum Kind {
        case identifier
        case number
        case punctuation
        case string
    }

    let endOffset: Int
    let kind: Kind
    let line: Int
    let startOffset: Int
    let text: String
}

struct Parser {
    struct Output {
        var resourceBindings: [AdaScriptResourceBinding] = []
        var schemas: [AdaScriptDataSchema] = []
        var scriptables: [AdaScriptableSchema] = []
        var systemCapabilities: [AdaScriptSystemCapabilities] = []
        var tools: [AdaScriptToolSchema] = []
        var views: [AdaScriptViewSchema] = []
    }

    let path: String
    let tokens: [Token]
    var index = 0

    init(source: String, path: String) {
        var lexer = Lexer(source: source)
        self.tokens = lexer.lex()
        self.path = path
    }
}
