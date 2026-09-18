import Foundation

struct GravityAPIMember: Hashable, Sendable {
    var detail: String
    var insertText: String
    var kind: GravityCompletionKind
    var name: String
    var returnType: String?

    init(
        _ name: String,
        detail: String,
        insertText: String? = nil,
        kind: GravityCompletionKind,
        returnType: String? = nil
    ) {
        self.detail = detail
        self.insertText = insertText ?? (kind == .method ? "\(name)()" : name)
        self.kind = kind
        self.name = name
        self.returnType = returnType
    }

    var completionCandidate: GravityCompletionCandidate {
        GravityCompletionCandidate(
            detail: detail,
            insertText: insertText,
            kind: kind,
            label: name,
            sortText: "00"
        )
    }
}

enum GravityAPICatalog {
    static let systemContextType = "$AdaSystemContext"
    static let editorToolContextType = "$AdaEditorToolContext"

    static let members: [String: [GravityAPIMember]] = [
        "$AdaCommands": [
            GravityAPIMember(
                "despawn",
                detail: "despawn(entityID) -> Bool — remove an entity through deferred commands",
                insertText: "despawn(entityID)",
                kind: .method,
                returnType: "Bool"
            ),
            GravityAPIMember(
                "insert",
                detail: "insert(entityID, componentName) -> Bool — insert a default component",
                insertText: "insert(entityID, componentName)",
                kind: .method,
                returnType: "Bool"
            ),
            GravityAPIMember(
                "remove",
                detail: "remove(entityID, componentName) -> Bool — remove a component",
                insertText: "remove(entityID, componentName)",
                kind: .method,
                returnType: "Bool"
            ),
            GravityAPIMember(
                "spawn",
                detail: "spawn(componentNames) -> Int — spawn an entity through deferred commands",
                insertText: "spawn(componentNames)",
                kind: .method,
                returnType: "Int"
            ),
        ],
        "$AdaEntity": [
            GravityAPIMember("id", detail: "Entity identifier", kind: .property, returnType: "Int")
        ],
        "$AdaSystemContext": [
            GravityAPIMember("deltaTime", detail: "Frame delta time in seconds", kind: .property, returnType: "Double"),
            GravityAPIMember("world", detail: "Scoped AdaECS world access", kind: .property, returnType: "$AdaWorldContext"),
        ],
        "$AdaWorldContext": [
            GravityAPIMember("commands", detail: "Scoped deferred world commands", kind: .property, returnType: "$AdaCommands")
        ],
        "$AdaEditorToolContext": [
            GravityAPIMember(
                "addCommand",
                detail: "addCommand(id, title, category, action) — register an editor command",
                insertText: "addCommand(id: \"\", title: \"\", category: \"\", action: \"\")",
                kind: .method
            ),
            GravityAPIMember(
                "addContextMenuItem",
                detail: "addContextMenuItem(command, location, when) — contribute a contextual command",
                insertText: "addContextMenuItem(command: \"\", location: \"\", when: \"\")",
                kind: .method
            ),
            GravityAPIMember(
                "addFormatter",
                detail: "addFormatter(id, languages, supportsSelection, action) — register a document formatter",
                insertText: "addFormatter(id: \"\", languages: [], supportsSelection: true, action: \"\")",
                kind: .method
            ),
            GravityAPIMember(
                "addMenuItem",
                detail: "addMenuItem(command, path, order) — contribute a menu item",
                insertText: "addMenuItem(command: \"\", path: \"\", order: 100)",
                kind: .method
            ),
            GravityAPIMember(
                "addPanel",
                detail: "addPanel(id, title, location, view) — register an AdaUI editor panel",
                insertText: "addPanel(id: \"\", title: \"\", location: \"right\", view: \"\")",
                kind: .method
            ),
            GravityAPIMember(
                "addSetting",
                detail: "addSetting(id, title, type, default, scope) — register a typed setting",
                insertText: "addSetting(id: \"\", title: \"\", type: \"string\", default: \"\", scope: \"workspace\")",
                kind: .method
            ),
            GravityAPIMember(
                "subscribe",
                detail: "subscribe(event, action) — subscribe to a supported editor event",
                insertText: "subscribe(event: \"\", action: \"\")",
                kind: .method
            ),
        ],
        "View": [
            viewMember("accessibilityIdentifier", detail: "Set an AdaUI accessibility identifier"),
            viewMember("background", detail: "Set a named or hexadecimal background color"),
            viewMember("child", detail: "Append a child to a stack"),
            viewMember("divider", detail: "Create an AdaUI divider"),
            viewMember("empty", detail: "Create an empty AdaUI view"),
            viewMember("fontSize", detail: "Set the inherited font size"),
            viewMember("foregroundColor", detail: "Set a named or hexadecimal foreground color"),
            viewMember("frame", detail: "Set a fixed width and height"),
            viewMember("hStack", detail: "Create a horizontal AdaUI stack"),
            viewMember("opacity", detail: "Set view opacity"),
            viewMember("padding", detail: "Add equal padding on every edge"),
            viewMember("spacer", detail: "Create a flexible AdaUI spacer"),
            viewMember("spacing", detail: "Set stack spacing"),
            viewMember("text", detail: "Create an AdaUI text view"),
            viewMember("vStack", detail: "Create a vertical AdaUI stack"),
            viewMember("zStack", detail: "Create an overlaying AdaUI stack"),
        ],
    ]

    static func member(named name: String, in type: String) -> GravityAPIMember? {
        members[type]?.first { $0.name == name }
    }

    private static func viewMember(_ name: String, detail: String) -> GravityAPIMember {
        GravityAPIMember(name, detail: detail, kind: .method, returnType: "View")
    }
}
