import Foundation

/// Public Store metadata is reference data, never executable agent instructions.
struct EditorAssetStoreClient: Sendable {
    static let maximumArchiveBytes: Int64 = 300_000_000
    let baseURL: URL?
    let session: URLSession

    init(baseURL: URL? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL ?? URL(string: "https://store.adaengine.org")
        self.session = session
    }

    static func assetID(from url: URL) -> String? {
        guard url.scheme == "adaeditor", url.host == "store", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "asset", let id = UUID(uuidString: String(parts[1])),
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/asset/" + String(parts[1]) else { return nil }
        return id.uuidString.lowercased()
    }

    func metadata(id: String) async throws -> Data {
        guard UUID(uuidString: id) != nil else { throw StoreError("Invalid asset ID.") }
        return try await get("assets/" + id)
    }

    func search(query: String, category: String?, sort: String = "popular", limit: Int = 24) async throws -> Data {
        guard query.utf8.count <= 200, ["popular", "rating", "newest"].contains(sort), (1...100).contains(limit) else {
            throw StoreError("Invalid search query, sort or limit.")
        }
        var items = [URLQueryItem(name: "q", value: query), .init(name: "sort", value: sort), .init(name: "limit", value: String(limit))]
        if let category { items.append(.init(name: "category", value: category)) }
        return try await get("assets", query: items)
    }

    func categories() async throws -> Data { try await get("categories") }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        guard let baseURL else { throw StoreError("Invalid Store configuration.") }
        var parts = URLComponents(url: baseURL.appendingPathComponent("v1/store/" + path), resolvingAgainstBaseURL: false)
        parts?.queryItems = query.isEmpty ? nil : query
        guard let url = parts?.url else { throw StoreError("Invalid Store URL.") }
        var request = URLRequest(url: url); request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw StoreError("Ada Store is unavailable or this asset was removed.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_000_000 else { throw StoreError("Store response is too large.") }
            data.append(byte)
        }
        return data
    }

    /// Save a package to a chosen destination; extracting/importing remains a separate action.
    func download(id: String, to destination: URL) async throws {
        guard UUID(uuidString: id) != nil else { throw StoreError("Invalid asset ID.") }
        guard let baseURL else { throw StoreError("Invalid Store configuration.") }
        let url = baseURL.appendingPathComponent("v1/store/assets/" + id + "/download")
        var request = URLRequest(url: url); request.timeoutInterval = 300
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= Self.maximumArchiveBytes else { throw StoreError("Asset download failed or exceeds 300 MB.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw StoreError("Could not create a temporary package.") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        var chunk = Data(), count: Int64 = 0
        for try await byte in bytes {
            count += 1
            guard count <= Self.maximumArchiveBytes else { throw StoreError("Asset exceeds 300 MB.") }
            chunk.append(byte)
            if chunk.count >= 65536 { try handle.write(contentsOf: chunk); chunk.removeAll(keepingCapacity: true) }
        }
        try handle.write(contentsOf: chunk)
        guard count > 0, response.expectedContentLength < 0 || count == response.expectedContentLength else { throw StoreError("Incomplete asset download.") }
        // copyItem refuses to overwrite existing project files.
        try FileManager.default.copyItem(at: temporary, to: destination)
    }

    struct StoreError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
