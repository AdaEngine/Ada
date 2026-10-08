import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct EditorCommunityGame: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let description: String
    let tags: [String]
    let likes: Int64
    let coverURL: URL?
    let screenshotURLs: [URL]
    let playURL: URL

    func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        let text = ([title, description] + tags).joined(separator: " ")
        return terms.allSatisfy { text.localizedStandardContains(String($0)) }
    }
}

/// Public game discovery uses no account credentials and never requests draft pages.
struct EditorCommunityClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    let server: URL
    var transport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CommunityError.invalidResponse }
        return (data, response)
    }

    func games(now: Date = Date()) async throws -> [EditorCommunityGame] {
        var request = URLRequest(url: server.appendingPathComponent("v1/catalog"))
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(request)
        guard response.statusCode == 200 else { throw CommunityError.http(response.statusCode) }
        let value = try JSONDecoder().decode(EditorCloudValue.self, from: data)
        guard case .array(let pages) = value else { throw CommunityError.invalidResponse }
        var seen = Set<String>()
        return pages.compactMap { page in
            guard let game = game(page, now: now), seen.insert(game.id).inserted else {
                return nil
            }
            return game
        }
    }

    func game(id: String, now: Date = Date()) async throws -> EditorCommunityGame {
        guard UUID(uuidString: id) != nil else { throw CommunityError.invalidResponse }
        var request = URLRequest(url: server.appendingPathComponent("v1/catalog").appendingPathComponent(id))
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(request)
        guard response.statusCode != 404 && response.statusCode != 410 else { throw CommunityError.unavailable }
        guard response.statusCode == 200 else { throw CommunityError.http(response.statusCode) }
        let page = try JSONDecoder().decode(EditorCloudValue.self, from: data)
        guard let game = game(page, now: now), game.id == id else { throw CommunityError.unavailable }
        return game
    }

    private func game(_ page: EditorCloudValue, now: Date) -> EditorCommunityGame? {
        let publication = page["publication"]
        guard page["published"].bool == true, page["blocked"].bool != true,
              publication["revoked"].bool != true,
              let id = page["id"].string, UUID(uuidString: id) != nil,
              let title = page["title"].string, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let address = publication["url"].string, let playURL = webURL(address) else {
            return nil
        }
        if publication["mode"].string == "ugc" {
            guard publication["approved"].bool == true, publication["expiresAt"] == .null,
                  publication["releaseId"].string != nil else {
                return nil
            }
        } else {
            guard publication["mode"].string == "catalog", publication["expiresAt"].seconds > now.timeIntervalSince1970 else {
                return nil
            }
        }
        return EditorCommunityGame(
            id: id,
            title: title,
            description: page["description"].string ?? "",
            tags: page["tags"].array.compactMap(\.string),
            likes: max(0, page["likes"].int ?? 0),
            coverURL: mediaURL(page["cover"].string),
            screenshotURLs: page["screenshots"].array.compactMap { mediaURL($0.string) },
            playURL: playURL
        )
    }

    private func mediaURL(_ id: String?) -> URL? {
        guard let id, UUID(uuidString: id) != nil else {
            return nil
        }
        var url = URLComponents(url: server.appendingPathComponent("v1/media").appendingPathComponent(id), resolvingAgainstBaseURL: false)
        url?.queryItems = [URLQueryItem(name: "format", value: "png")]
        return url?.url
    }

    private func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else {
            return nil
        }
        return url
    }

    enum CommunityError: LocalizedError {
        case invalidResponse
        case http(Int)
        case unavailable
        var errorDescription: String? {
            switch self {
            case .invalidResponse: "The community catalog returned an invalid response."
            case .http: "The community catalog is unavailable. Please try again."
            case .unavailable: "This world is no longer available. Refresh the community to see current worlds."
            }
        }
    }
}
