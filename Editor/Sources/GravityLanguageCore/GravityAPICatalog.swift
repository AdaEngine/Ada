import AdaScriptCompilerCore

struct GravityAPIMember: Hashable, Sendable {
    var detail: String
    var insertText: String
    var kind: GravityCompletionKind
    var name: String
    var returnType: String?

    init(name: String, member: AdaScriptMemberType) {
        self.detail = member.detail ?? "AdaScript \(member.kind == .method ? "method" : "property")"
        self.insertText = member.insertText ?? (member.kind == .method ? "\(name)()" : name)
        self.kind = member.kind == .method ? .method : .property
        self.name = name
        self.returnType = member.type == .unknown ? nil : member.type.displayName
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
    static let editorToolContextType = "$AdaEditorToolContext"
    static let systemContextType = "$AdaSystemContext"

    static let members: [String: [GravityAPIMember]] = AdaScriptTypeEnvironment.standard.members.mapValues { members in
        members.map { name, member in
            GravityAPIMember(name: name, member: member)
        }
        .sorted { $0.name < $1.name }
    }

    static func member(named name: String, in type: String) -> GravityAPIMember? {
        members[type]?.first { $0.name == name }
    }
}
