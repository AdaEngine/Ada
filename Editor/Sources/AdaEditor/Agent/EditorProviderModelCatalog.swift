import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct EditorProviderModel: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
}

enum EditorProviderModelCatalog {
    // The backend gates model availability by the advertised Codex protocol version.
    static let codexClientVersion = "0.158.0"

    enum CatalogError: Error, LocalizedError {
        case invalidURL
        case http(Int)
        case invalidResponse
        case empty

        var errorDescription: String? {
            switch self {
            case .invalidURL: "Enter a valid HTTPS API URL. HTTP is supported for localhost."
            case .http(401), .http(403): "Access denied. Check your API key or reconnect Codex."
            case .http(let status): "Could not load models (HTTP \(status)). Try again."
            case .invalidResponse: "The provider returned an invalid model list."
            case .empty: "No models are available for this account."
            }
        }
    }

    static func apiRequest(baseURL: String, apiKey: String) throws -> URLRequest {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
        else { throw CatalogError.invalidURL }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = path.isEmpty ? "/v1/models" : "/\(path)/models"
        guard let url = components.url else { throw CatalogError.invalidURL }
        return authorizedRequest(url: url, token: apiKey)
    }

    static func codexRequest(accessToken: String, accountID: String?) throws -> URLRequest {
        guard let url = URL(string: "https://chatgpt.com/backend-api/codex/models?client_version=\(codexClientVersion)") else {
            throw CatalogError.invalidURL
        }
        var request = authorizedRequest(url: url, token: accessToken)
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return request
    }

    static func fetch(_ request: URLRequest, session: URLSession = .shared) async throws -> [EditorProviderModel] {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CatalogError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw CatalogError.http(response.statusCode) }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> [EditorProviderModel] {
        let object = try JSONSerialization.jsonObject(with: data)
        let dictionary = object as? [String: Any]
        guard let items = (object as? [[String: Any]])
            ?? (dictionary?["models"] as? [[String: Any]])
            ?? (dictionary?["data"] as? [[String: Any]])
            ?? (dictionary?["items"] as? [[String: Any]]) else { throw CatalogError.invalidResponse }
        var seen = Set<String>()
        let models = items.compactMap { item -> EditorProviderModel? in
            guard item["visibility"] as? String != "hide",
                  let id = (item["id"] as? String ?? item["slug"] as? String ?? item["name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty, seen.insert(id).inserted else { return nil }
            return EditorProviderModel(id: id, title: item["display_name"] as? String ?? item["title"] as? String ?? id)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        guard !models.isEmpty else { throw CatalogError.empty }
        return models
    }

    static func matching(_ models: [EditorProviderModel], query: String) -> [EditorProviderModel] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }

    private static func authorizedRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
