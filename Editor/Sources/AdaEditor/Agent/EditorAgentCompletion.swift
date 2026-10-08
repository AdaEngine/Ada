import Foundation

struct EditorAgentCommand: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var description: String
    var inputHint: String?
    var id: String { name }
}

enum EditorAgentCompletion: Equatable, Identifiable, Sendable {
    case file(EditorAgentProjectFileSearch.Entry)
    case skill(EditorAgentSkill)
    case command(EditorAgentCommand)

    var id: String {
        switch self {
        case let .file(file): "file:\(file.path)"
        case let .skill(skill): "skill:\(skill.id)"
        case let .command(command): "command:\(command.name)"
        }
    }

    var title: String {
        switch self {
        case let .file(file): file.path
        case let .skill(skill): skill.id
        case let .command(command): command.name
        }
    }

    var kind: String {
        switch self {
        case let .file(file): file.isDirectory ? "Folder" : "File"
        case .skill: "Skill"
        case .command: "Command"
        }
    }

    var detail: String? {
        switch self {
        case .file: nil
        case let .skill(skill): skill.description
        case let .command(command): command.description
        }
    }
}

struct EditorAgentCompletionToken {
    var marker: Character
    var query: String
    var range: Range<String.Index>

    static func current(in text: String, cursorOffset: Int?) -> Self? {
        let end = text.index(text.startIndex, offsetBy: min(max(cursorOffset ?? text.count, 0), text.count))
        if let token = EditorAgentPathTokens.tokenBeforeCursor(in: text, cursorOffset: cursorOffset) {
            return Self(marker: "@", query: token.path, range: token.range)
        }
        let prefix = text[..<end]
        if prefix.last == "@" {
            return Self(marker: "@", query: "", range: text.index(before: end)..<end)
        }
        let leadingCount = prefix.prefix(while: \.isWhitespace).count
        let start = text.index(text.startIndex, offsetBy: leadingCount)
        guard start < end, text[start] == "/" else {
            return nil
        }
        let query = text[text.index(after: start)..<end]
        guard !query.contains(where: \.isWhitespace) else {
            return nil
        }
        return Self(marker: "/", query: String(query), range: start..<end)
    }

    func matches(_ value: String) -> Bool {
        let query = query.hasPrefix("skill:") ? String(query.dropFirst(6)) : query
        return query.isEmpty || value.localizedCaseInsensitiveContains(query)
    }
}
