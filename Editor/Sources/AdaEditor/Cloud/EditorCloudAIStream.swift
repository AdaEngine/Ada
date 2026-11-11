import Foundation

typealias EditorCloudAITransport = @Sendable (EditorCloudValue, @escaping @Sendable (EditorCloudValue) async throws -> Void) async throws -> Void

struct EditorCloudAIConnection: Sendable {
    let toolContract: Int64?
    let generate: EditorCloudAITransport
}

/// Parses only our server's normalized SSE contract; upstream provider data stays on Cloud.
struct EditorCloudAIStream {
    private(set) var complete = false
    mutating func event(line: String) throws -> EditorCloudValue? {
        guard line.utf8.count <= 2 * 1024 * 1024 else { throw EditorAIError.invalidResponse }
        guard line.hasPrefix("data:") else { return nil }
        guard !complete else { throw EditorAIError.invalidResponse }
        let data = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
        let event = try JSONDecoder().decode(EditorCloudValue.self, from: data)
        guard let type = event["type"].string, ["text", "tool", "usage", "complete", "error"].contains(type) else { throw EditorAIError.invalidResponse }
        if type == "error" { throw EditorCloudAccount.CloudError.message("Generation interrupted. Your saved project is available; check your AI credits before continuing.") }
        if type == "complete" { complete = true }
        return event
    }
    func finish() throws { guard complete else { throw EditorAIError.invalidResponse } }
}
