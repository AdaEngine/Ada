/// The AdaEngine annotations and where each may appear. One table serves the runtime, the build
/// generator, and the Editor language service, so they cannot disagree about what is valid.
public enum AdaScriptAnnotationCatalog {
    public struct Rule: Equatable, Sendable {
        public let detail: String
        public let name: String
        public let targets: Set<AdaScriptAnnotationUse.Target>
    }

    /// One misplaced or unknown annotation.
    public struct Problem: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case unknown
            case unsupportedTarget
        }

        public let kind: Kind
        public let message: String
        public let use: AdaScriptAnnotationUse
    }

    public static let rules: [String: Rule] = Dictionary(
        uniqueKeysWithValues: [
            rule("access", [.class], "Declare the components the dynamic world API may read or write"),
            rule("after", [.class], "Run a system after another system"),
            rule("before", [.class], "Run a system before another system"),
            rule("binding", [.property], "Bind a view property to its parent"),
            rule("component", [.struct, .property], "Declare an AdaScript component, or bind one on a scriptable object"),
            rule("environment", [.property], "Read an AdaUI environment value"),
            rule("eventWriter", [.property], "Bind a writer for one event name"),
            rule("events", [.property], "Bind the events of one name received since the previous frame"),
            rule("exclusiveWorld", [.class], "Allow immediate structural world changes"),
            rule("export", [.property], "Export a stored field; group: \"Camera/Auto Exposure\" defines up to four inspector subgroup levels"),
            rule("local", [.property], "Keep a replicated field local"),
            rule("network_command", [.struct], "Declare a typed network command"),
            rule("network_field", [.property, .parameter], "Tag a replicated field or RPC parameter"),
            rule("nonsendable", [.class, .struct, .enum], "Mark a type that must not cross a suspension"),
            rule("previewable", [.class, .struct], "Expose an AdaUI view in Editor previews"),
            rule("query", [.property], "Declare an iterator-based ECS query"),
            rule("remote_commands", [.property], "Bind received network commands of one type"),
            rule("replicated_component", [.struct], "Declare a replicated component"),
            rule("res", [.property], "Bind an ECS resource"),
            rule("resource", [.struct, .property], "Declare an AdaScript resource, or bind one on a scriptable object"),
            rule("rpc", [.function, .method], "Declare a remote procedure"),
            rule("scriptable", [.class], "Declare a serializable AdaScript object"),
            rule("state", [.property], "Declare view-owned reactive state"),
            rule("strict", [.module], "Enable strict type checking for this file"),
            rule("system", [.class], "Declare an AdaEngine ECS system"),
            rule("test", [.function], "Declare an Ada Script test"),
            rule("tool", [.class], "Declare an AdaEditor tool"),
            rule("view", [.class, .struct], "Declare an AdaUI view"),
        ]
    )

    public static var names: [String] { rules.keys.sorted() }

    /// Unknown annotations and annotations on a target they do not support.
    public static func problems(in uses: [AdaScriptAnnotationUse]) -> [Problem] {
        uses.compactMap { use in
            guard let rule = rules[use.name] else {
                return Problem(kind: .unknown, message: "Unknown annotation @\(use.name)", use: use)
            }
            guard !rule.targets.contains(use.target) else {
                return nil
            }
            return Problem(
                kind: .unsupportedTarget,
                message: "@\(use.name) cannot annotate \(describe(use.target)); it applies to \(describe(rule.targets))",
                use: use
            )
        }
    }

    private static func rule(_ name: String, _ targets: Set<AdaScriptAnnotationUse.Target>, _ detail: String) -> (String, Rule) {
        (name, Rule(detail: detail, name: name, targets: targets))
    }

    private static func describe(_ target: AdaScriptAnnotationUse.Target) -> String {
        switch target {
        case .class: "a class"
        case .enum: "an enum"
        case .struct: "a struct"
        case .function: "a function"
        case .method: "a method"
        case .property: "a stored property"
        case .variable: "a top-level variable"
        case .parameter: "a parameter"
        case .module: "a file"
        }
    }

    private static func describe(_ targets: Set<AdaScriptAnnotationUse.Target>) -> String {
        targets.map(describe).sorted().joined(separator: " or ")
    }
}
