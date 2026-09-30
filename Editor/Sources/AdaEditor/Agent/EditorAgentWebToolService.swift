import Foundation
import MCP

@MainActor
final class EditorAgentWebToolService {
    private let projectURL: URL?
    private let client: any EditorWebHTTPClient

    init(projectURL: URL? = nil, client: any EditorWebHTTPClient = EditorWebURLSessionClient()) {
        self.projectURL = projectURL?.standardizedFileURL.resolvingSymlinksInPath()
        self.client = client
    }

    func execute(name: String, arguments: [String: Value]) async throws -> [String: Any] {
        switch name {
        case "editor.web.search":
            let query = try string("query", arguments).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, query.count <= 1000 else { throw EditorWebToolError("query must contain 1...1000 characters.") }
            let count = try integer("count", arguments, fallback: 5, range: 1...10)
            var components = URLComponents(string: "https://search.brave.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: query)]
            guard let url = components?.url else { throw EditorWebToolError("Invalid search query.") }
            let response = try await get(url, maxBytes: 2 * 1024 * 1024)
            let html = try text(response)
            let results = EditorWebHTML.searchResults(html, count: count)
            guard !results.isEmpty else {
                throw EditorWebToolError("Search returned no readable results; the provider may have blocked the request or shown a challenge. Try another query or fetch a known URL.")
            }
            return ["query": query, "provider": "Brave Search HTML", "url": response.url.absoluteString, "results": results, "untrustedContent": true]
        case "editor.web.fetch":
            let url = try sourceURL(arguments)
            let maximum = try integer("maxCharacters", arguments, fallback: 20000, range: 1...50000)
            let response = try await get(url, maxBytes: 2 * 1024 * 1024)
            let source = try text(response)
            let isHTML = response.mimeType == "text/html" || response.mimeType == "application/xhtml+xml"
            let content = isHTML ? EditorWebHTML.text(source) : source
            return [
                "url": response.url.absoluteString, "sourceURL": url.absoluteString, "mimeType": response.mimeType,
                "title": isHTML ? EditorWebHTML.title(source) : "", "text": String(content.prefix(maximum)),
                "truncated": content.count > maximum, "links": isHTML ? EditorWebHTML.links(source, base: response.url) : [],
                "untrustedContent": true,
            ]
        case "editor.web.download":
            let url = try sourceURL(arguments)
            let path = try string("destination", arguments)
            let destination = try resolve(path)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw EditorWebToolError("Destination already exists: \(path)") }
            let maximum = try integer("maxBytes", arguments, fallback: 16 * 1024 * 1024, range: 1...(16 * 1024 * 1024))
            let response = try await get(url, maxBytes: maximum)
            try Task.checkCancellation()
            // Recheck after suspension before touching the filesystem.
            let checked = try resolve(path)
            guard checked == destination else { throw EditorWebToolError("Download destination changed during the request.") }
            try FileManager.default.createDirectory(at: checked.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = checked.deletingLastPathComponent().appendingPathComponent(".web-download-\(UUID())")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try response.data.write(to: temporary, options: .atomic)
            // moveItem fails if the target exists, including a file created while the request was in flight.
            try FileManager.default.moveItem(at: temporary, to: checked)
            return ["path": path, "sourceURL": url.absoluteString, "url": response.url.absoluteString, "mimeType": response.mimeType, "bytes": response.data.count]
        default:
            throw EditorWebToolError("Unknown web tool: \(name)")
        }
    }

    private func get(_ url: URL, maxBytes: Int) async throws -> EditorWebHTTPResponse {
        try EditorWebURLSessionClient.validate(url)
        let response = try await client.get(url, maxBytes: maxBytes)
        try EditorWebURLSessionClient.validate(response.url)
        guard response.data.count <= maxBytes else { throw EditorWebToolError("Response exceeds the \(maxBytes)-byte limit.") }
        return response
    }

    private func text(_ response: EditorWebHTTPResponse) throws -> String {
        let type = response.mimeType.lowercased()
        let textTypes = ["application/json", "application/xml", "application/xhtml+xml", "application/javascript"]
        guard type.hasPrefix("text/") || textTypes.contains(type) || type.hasSuffix("+json") || type.hasSuffix("+xml") else {
            throw EditorWebToolError("Binary content (\(type)); use editor.web.download instead.")
        }
        if let value = String(data: response.data, encoding: .utf8) {
            return value
        }
        let encoding = response.textEncodingName?.lowercased()
        if ["iso-8859-1", "latin1", "windows-1252"].contains(encoding ?? ""), let value = String(data: response.data, encoding: encoding == "windows-1252" ? .windowsCP1252 : .isoLatin1) {
            return value
        }
        throw EditorWebToolError("Page has an unsupported text encoding. Download the original file instead.")
    }

    private func resolve(_ path: String) throws -> URL {
        guard let projectURL else { throw EditorWebToolError("Open a project before downloading files.") }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, ["Assets", "Downloads"].contains(parts.first.map(String.init) ?? ""),
              parts.allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." && !$0.hasPrefix(".") }), !path.contains("\\") else {
            throw EditorWebToolError("destination must be a project-relative file under Assets or Downloads without traversal or hidden components.")
        }
        var url = projectURL
        for part in parts {
            url.appendPathComponent(String(part))
            // resolvingSymlinksInPath may leave a missing leaf unresolved. Check each existing
            // ancestor explicitly, including dangling symlinks, before creating directories.
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else {
                throw EditorWebToolError("Download destination cannot contain symbolic links.")
            }
        }
        url = url.standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathComponents.starts(with: projectURL.pathComponents), url.pathComponents.count > projectURL.pathComponents.count else {
            throw EditorWebToolError("Download destination is outside the project.")
        }
        return url
    }

    private func sourceURL(_ arguments: [String: Value]) throws -> URL {
        guard let url = URL(string: try string("url", arguments)) else { throw EditorWebToolError("Invalid URL.") }
        try EditorWebURLSessionClient.validate(url)
        return url
    }

    private func string(_ key: String, _ arguments: [String: Value]) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else { throw EditorWebToolError("Missing \(key).") }
        return value
    }

    private func integer(_ key: String, _ arguments: [String: Value], fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = arguments[key] else {
            return fallback
        }
        guard case let .int(number) = value, range.contains(number) else { throw EditorWebToolError("\(key) must be an integer in \(range).") }
        return number
    }
}
