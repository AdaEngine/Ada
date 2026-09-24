import Foundation

struct GravityCompletionCandidate: Hashable, Sendable {
    var detail: String
    var insertText: String
    var kind: GravityCompletionKind
    var label: String
    var sortText: String

    init(detail: String, insertText: String, kind: GravityCompletionKind, label: String, sortText: String) {
        self.detail = detail
        self.insertText = insertText
        self.kind = kind
        self.label = label
        self.sortText = sortText
    }

    init(symbol: GravitySymbol) {
        kind =
            switch symbol.kind {
            case .class: .class
            case .enum: .enum
            case .function: .function
            case .method: .method
            case .struct: .struct
            case .field,
                .property:
                .property
            default: .variable
            }
        detail = symbol.detail
        insertText =
            switch symbol.kind {
            case .function,
                .method:
                "\(symbol.name)()"
            default: symbol.name
            }
        label = symbol.name
        sortText = symbol.kind == .class || symbol.kind == .struct || symbol.kind == .enum ? "20" : "21"
    }
}

enum GravityBuiltins {
    static let members = GravityAPICatalog.members.mapValues { $0.map(\.completionCandidate) }

    static let annotationCandidates: [GravityCompletionCandidate] = [
        GravityCompletionCandidate(
            detail: "Declare an AdaEngine ECS system",
            insertText: "system(scheduler: \"update\")",
            kind: .keyword,
            label: "system",
            sortText: "00"
        ),
        GravityCompletionCandidate(
            detail: "Declare an iterator-based ECS query",
            insertText: "query()",
            kind: .keyword,
            label: "query",
            sortText: "01"
        ),
        GravityCompletionCandidate(
            detail: "Declare explicit scheduler access",
            insertText: "access(read: [], write: [])",
            kind: .keyword,
            label: "access",
            sortText: "02"
        ),
        GravityCompletionCandidate(
            detail: "Declare an AdaScript component",
            insertText: "component(id: \"\")",
            kind: .keyword,
            label: "component",
            sortText: "03"
        ),
        GravityCompletionCandidate(
            detail: "Declare an AdaScript resource",
            insertText: "resource(id: \"\")",
            kind: .keyword,
            label: "resource",
            sortText: "04"
        ),
        GravityCompletionCandidate(
            detail: "Declare a serializable AdaScript object",
            insertText: "scriptable(id: \"\")",
            kind: .keyword,
            label: "scriptable",
            sortText: "05"
        ),
        GravityCompletionCandidate(
            detail: "Export a stored scriptable property",
            insertText: "export",
            kind: .keyword,
            label: "export",
            sortText: "06"
        ),
        GravityCompletionCandidate(
            detail: "Declare an AdaUI view",
            insertText: "view",
            kind: .keyword,
            label: "view",
            sortText: "07"
        ),
        GravityCompletionCandidate(
            detail: "Expose an AdaUI view in AdaEditor previews",
            insertText: "previewable",
            kind: .keyword,
            label: "previewable",
            sortText: "08"
        ),
        GravityCompletionCandidate(
            detail: "Declare view-owned reactive state",
            insertText: "state",
            kind: .keyword,
            label: "state",
            sortText: "09"
        ),
        GravityCompletionCandidate(
            detail: "Read an AdaUI environment value",
            insertText: "environment()",
            kind: .keyword,
            label: "environment",
            sortText: "10"
        ),
        GravityCompletionCandidate(
            detail: "Declare an AdaEditor tool",
            insertText: "tool(id: \"\", name: \"\", version: \"1.0.0\", api: 1, platforms: [\"macos\", \"ipados\"], permissions: [])",
            kind: .keyword,
            label: "tool",
            sortText: "11"
        ),
    ]

    static let globalCandidates: [GravityCompletionCandidate] =
        [
            GravityCompletionCandidate(detail: "Function declaration", insertText: "func $name$() {\n    \n}", kind: .snippet, label: "func", sortText: "10"),
            GravityCompletionCandidate(detail: "Suspending function declaration", insertText: "async func $name$() {\n    \n}", kind: .snippet, label: "async func", sortText: "10"),
            GravityCompletionCandidate(detail: "Wait for an async task", insertText: "await ", kind: .keyword, label: "await", sortText: "10"),
            GravityCompletionCandidate(detail: "Class declaration", insertText: "class $Name$ {\n    \n}", kind: .snippet, label: "class", sortText: "11"),
            GravityCompletionCandidate(detail: "Variable declaration", insertText: "var ", kind: .keyword, label: "var", sortText: "12"),
            GravityCompletionCandidate(detail: "Return statement", insertText: "return ", kind: .keyword, label: "return", sortText: "13"),
            GravityCompletionCandidate(detail: "Conditional statement", insertText: "if () {\n    \n}", kind: .snippet, label: "if", sortText: "14"),
            GravityCompletionCandidate(detail: "Alternative branch", insertText: "else {\n    \n}", kind: .snippet, label: "else", sortText: "15"),
            GravityCompletionCandidate(detail: "For loop", insertText: "for (item in items) {\n    \n}", kind: .snippet, label: "for", sortText: "16"),
            GravityCompletionCandidate(detail: "While loop", insertText: "while () {\n    \n}", kind: .snippet, label: "while", sortText: "17"),
            GravityCompletionCandidate(detail: "AdaUI text", insertText: "Text(\"\")", kind: .class, label: "Text", sortText: "18"),
            GravityCompletionCandidate(detail: "Vertical AdaUI stack", insertText: "VStack {\n    \n}", kind: .class, label: "VStack", sortText: "18"),
            GravityCompletionCandidate(detail: "Horizontal AdaUI stack", insertText: "HStack {\n    \n}", kind: .class, label: "HStack", sortText: "18"),
            GravityCompletionCandidate(detail: "Overlaying AdaUI stack", insertText: "ZStack {\n    \n}", kind: .class, label: "ZStack", sortText: "18"),
            GravityCompletionCandidate(detail: "Flexible AdaUI space", insertText: "Spacer()", kind: .class, label: "Spacer", sortText: "18"),
            GravityCompletionCandidate(detail: "AdaUI divider", insertText: "Divider()", kind: .class, label: "Divider", sortText: "18"),
            GravityCompletionCandidate(detail: "AdaEngine asset manager", insertText: "Assets", kind: .variable, label: "Assets", sortText: "18"),
            GravityCompletionCandidate(detail: "AdaScript task scheduler", insertText: "Tasks", kind: .class, label: "Tasks", sortText: "18"),
            GravityCompletionCandidate(detail: "AdaScript timers", insertText: "Time", kind: .class, label: "Time", sortText: "18"),
            GravityCompletionCandidate(detail: "Background save operations", insertText: "Saves", kind: .class, label: "Saves", sortText: "18"),
            GravityCompletionCandidate(
                detail: "Three-dimensional vector",
                insertText: "Vector3(0, 0, 0)",
                kind: .class,
                label: "Vector3",
                sortText: "18"
            ),
        ] + keywordCandidates

    private static let keywordCandidates = [
        "break", "case", "const", "continue", "enum", "event", "extern", "false", "import", "null", "private", "public", "repeat", "static", "struct", "switch", "true",
    ]
    .enumerated()
    .map { index, keyword in
        GravityCompletionCandidate(detail: "AdaScript keyword", insertText: keyword, kind: .keyword, label: keyword, sortText: "\(30 + index)")
    }
}
