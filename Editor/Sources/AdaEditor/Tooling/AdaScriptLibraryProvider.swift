import AdaScriptCompilerCore
import Foundation

struct AdaScriptLibraryDownload: Sendable {
    var manifest: AdaScriptLibraryManifest
    var source: AdaScriptLibrarySource
    var files: [String: Data]

    func validate() throws {
        try manifest.validate()
        guard
            Set(files.keys) == Set(manifest.sources),
            files.values.reduce(0, { $0 + $1.count }) <= 8 * 1_024 * 1_024,
            files.values.allSatisfy({ $0.count <= 1_024 * 1_024 && String(bytes: $0, encoding: .utf8) != nil })
        else {
            throw AdaScriptLibraryError.invalid("Incomplete, oversized, or invalid library \(manifest.id).")
        }
    }
}

/// Store adapters return the same pinned manifest/source bundle as GitHub.
protocol AdaScriptLibraryProvider: Sendable {
    func download(_ source: AdaScriptLibrarySource) async throws -> AdaScriptLibraryDownload
}

struct GitHubAdaScriptLibraryProvider: AdaScriptLibraryProvider {
    typealias Request = @Sendable (URLRequest) async throws -> Data
    private let request: Request

    init(request: @escaping Request = Self.fetch) {
        self.request = request
    }

    static func source(repository: String, revision: String) throws -> AdaScriptLibrarySource {
        var location = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        if location.hasPrefix("https://github.com/") {
            location.removeFirst("https://github.com/".count)
        }
        if location.hasSuffix(".git") {
            location.removeLast(4)
        }
        guard
            location.range(of: #"^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
            !location.hasSuffix("/.."), !location.hasSuffix("/."), !revision.isEmpty,
            revision.count <= 200
        else {
            throw AdaScriptLibraryError.invalid("Enter a GitHub owner/repository and a tag or commit.")
        }
        return AdaScriptLibrarySource(provider: "github", location: location.lowercased(), revision: revision)
    }

    func download(_ source: AdaScriptLibrarySource) async throws -> AdaScriptLibraryDownload {
        guard source.provider == "github" else {
            throw AdaScriptLibraryError.invalid("Library provider '\(source.provider)' is not installed.")
        }
        let normalized = try Self.source(repository: source.location, revision: source.revision)
        let commit: Commit = try await get(location: normalized.location, path: ["commits", normalized.revision])
        guard Self.isCommit(commit.sha) else {
            throw AdaScriptLibraryError.invalid("GitHub returned an invalid commit.")
        }
        let pinned = AdaScriptLibrarySource(provider: "github", location: normalized.location, revision: commit.sha)
        let tree: Tree = try await get(location: pinned.location, path: ["git", "trees", commit.sha], recursive: true)
        guard !tree.truncated else {
            throw AdaScriptLibraryError.invalid("GitHub library tree is too large. Publish the library in a smaller repository.")
        }
        let manifestData = try await read("ada-library.json", tree: tree, location: pinned.location)
        let manifest = try JSONDecoder().decode(AdaScriptLibraryManifest.self, from: manifestData)
        try manifest.validate()
        for dependency in manifest.dependencies where dependency.source.provider == "github" {
            guard Self.isCommit(dependency.source.revision) else {
                throw AdaScriptLibraryError.invalid("Dependency \(dependency.id) must pin a full GitHub commit SHA.")
            }
        }
        var files: [String: Data] = [:]
        var byteCount = 0
        for path in manifest.sources {
            try Task.checkCancellation()
            let data = try await read(path, tree: tree, location: pinned.location)
            byteCount += data.count
            guard byteCount <= 8 * 1_024 * 1_024 else {
                throw AdaScriptLibraryError.invalid("AdaScript library exceeds the 8 MB source limit.")
            }
            files[path] = data
        }
        return AdaScriptLibraryDownload(manifest: manifest, source: pinned, files: files)
    }

    static func isCommit(_ revision: String) -> Bool {
        revision.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
    }

    private func read(_ path: String, tree: Tree, location: String) async throws -> Data {
        guard
            let entry = tree.tree.first(where: { $0.path == path }), entry.type == "blob",
            entry.mode == "100644" || entry.mode == "100755",
            let size = entry.size, size <= 1_024 * 1_024, Self.isCommit(entry.sha)
        else {
            throw AdaScriptLibraryError.invalid("Missing, oversized, or non-regular library file: \(path).")
        }
        let blob: Blob = try await get(location: location, path: ["git", "blobs", entry.sha])
        guard
            blob.encoding == "base64", let data = Data(base64Encoded: blob.content, options: .ignoreUnknownCharacters),
            data.count == size, String(bytes: data, encoding: .utf8) != nil
        else {
            throw AdaScriptLibraryError.invalid("Library file is not valid UTF-8: \(path).")
        }
        return data
    }

    private func get<Value: Decodable>(location: String, path: [String], recursive: Bool = false) async throws -> Value {
        guard var url = URL(string: "https://api.github.com/repos/\(location)") else {
            throw AdaScriptLibraryError.invalid("Invalid GitHub repository.")
        }
        for component in path {
            // appendingPathComponent preserves slash in branch names; encode it as one API segment.
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            guard
                let encoded = component.addingPercentEncoding(withAllowedCharacters: allowed),
                let next = URL(string: url.absoluteString + "/" + encoded)
            else {
                throw AdaScriptLibraryError.invalid("Invalid GitHub reference.")
            }
            url = next
        }
        if recursive {
            url.append(queryItems: [URLQueryItem(name: "recursive", value: "1")])
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        urlRequest.setValue("AdaEditor", forHTTPHeaderField: "User-Agent")
        return try await JSONDecoder().decode(Value.self, from: request(urlRequest))
    }

    private static func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AdaScriptLibraryError.invalid("GitHub request failed (HTTP \(status)). Check the public repository, revision, and API rate limit.")
        }
        guard data.count <= 10 * 1_024 * 1_024 else {
            throw AdaScriptLibraryError.invalid("GitHub response is too large.")
        }
        return data
    }

    private struct Commit: Decodable { var sha: String }
    private struct Tree: Decodable {
        var truncated: Bool
        var tree: [Entry]
    }
    private struct Entry: Decodable {
        var path: String
        var mode: String
        var type: String
        var sha: String
        var size: Int?
    }
    private struct Blob: Decodable {
        var content: String
        var encoding: String
    }
}
