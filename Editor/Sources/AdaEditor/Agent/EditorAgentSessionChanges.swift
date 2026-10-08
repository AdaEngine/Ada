import Foundation

struct EditorAgentChangedFile: Identifiable, Equatable, Sendable {
    var path: String
    var id: String { path }
    var title: String { URL(fileURLWithPath: path).lastPathComponent }
}

enum EditorAgentSessionChanges {
    /// Only completed diff events count as changes; reads and failed tools do not.
    static func files(in events: [EditorAgentEvent]) -> [EditorAgentChangedFile] {
        var paths = Set<String>()
        for event in events {
            guard let tool = event.toolCall, tool.status == .completed else { continue }
            for content in tool.content where content.kind == .diff {
                guard let path = content.path, !path.isEmpty else { continue }
                paths.insert(path)
            }
        }
        return paths.sorted().map { EditorAgentChangedFile(path: $0) }
    }
}
