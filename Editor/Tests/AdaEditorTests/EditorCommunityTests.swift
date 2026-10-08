@testable import AdaEditor
import Foundation
import Testing

@Suite("Community catalog")
struct EditorCommunityTests {
    private var server: URL { URL(string: "https://cloud.example.com") ?? URL(fileURLWithPath: "/") }
    private let pageID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let mediaID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    private func page() -> EditorCloudValue {
        [
            "id": .string(pageID), "title": "Moon Garden", "description": "Explore a quiet moon",
            "published": true, "blocked": false, "likes": 12, "tags": ["Adventure", "2D"],
            "cover": .string(mediaID), "screenshots": [.string(mediaID)],
            "publication": [
                "mode": "ugc", "approved": true, "expiresAt": nil, "revoked": false,
                "releaseId": "release-1", "url": "https://game.games.example.com/"
            ]
        ]
    }

    private func client(_ pages: [EditorCloudValue], status: Int = 200) throws -> EditorCommunityClient {
        let data = try JSONEncoder().encode(EditorCloudValue.array(pages))
        return EditorCommunityClient(server: server) { request in
            #expect(request.url?.absoluteString == "https://cloud.example.com/v1/catalog")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (data, try Self.response(for: request, status: status))
        }
    }

    private static func response(for request: URLRequest, status: Int) throws -> HTTPURLResponse {
        let url = try #require(request.url)
        return try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
    }

    @Test func publicMetadataMediaAndSearch() async throws {
        let games = try await client([page(), page()]).games()
        let game = try #require(games.first)
        #expect(games.count == 1)
        #expect(game.title == "Moon Garden")
        #expect(game.likes == 12)
        #expect(game.coverURL?.absoluteString == "https://cloud.example.com/v1/media/\(mediaID)?format=png")
        let cover = try #require(game.coverURL)
        #expect(game.screenshotURLs == [cover])
        #expect(game.matches("  MOON adventure  "))
        #expect(game.matches("quiet"))
        #expect(game.matches(" "))
        #expect(!game.matches("moon racing"))
    }

    @Test func unavailableReleasesAreExcluded() async throws {
        var draft = page(); draft["published"] = false
        var blocked = page(); blocked["blocked"] = true
        var revoked = page(); revoked["publication"]["revoked"] = true
        var pending = page(); pending["publication"]["approved"] = false
        var missingRelease = page(); missingRelease["publication"]["releaseId"] = nil
        var expiringUGC = page(); expiringUGC["publication"]["expiresAt"] = 2000
        var expired = page(); expired["publication"]["mode"] = "catalog"; expired["publication"]["expiresAt"] = 999
        var invite = page(); invite["publication"]["mode"] = "invite"
        #expect(try await client([draft, blocked, revoked, pending, missingRelease, expiringUGC, expired, invite])
            .games(now: Date(timeIntervalSince1970: 1000)).isEmpty)
        var catalog = expired; catalog["publication"]["expiresAt"] = 1001
        #expect(try await client([catalog]).games(now: Date(timeIntervalSince1970: 1000)).count == 1)
    }

    @Test func invalidLinksAndMediaAreRejected() async throws {
        var insecure = page(); insecure["publication"]["url"] = "http://example.com"
        var script = page(); script["publication"]["url"] = "javascript:alert(1)"
        var credentials = page(); credentials["publication"]["url"] = "https://user:pass@example.com"
        #expect(try await client([insecure, script, credentials]).games().isEmpty)
        var invalidMedia = page(); invalidMedia["cover"] = "../../private"; invalidMedia["screenshots"] = ["https://other.example.com/image"]
        let game = try #require(try await client([invalidMedia]).games().first)
        #expect(game.coverURL == nil)
        #expect(game.screenshotURLs.isEmpty)
    }

    @Test func emptyAndFailureAreDifferent() async throws {
        #expect(try await client([]).games().isEmpty)
        await #expect(throws: EditorCommunityClient.CommunityError.self) {
            try await client([], status: 503).games()
        }
        let malformed = EditorCommunityClient(server: server) { request in
            (Data("{}".utf8), try Self.response(for: request, status: 200))
        }
        await #expect(throws: EditorCommunityClient.CommunityError.self) { try await malformed.games() }
    }

    @Test func launchRechecksSelectedWorld() async throws {
        let data = try JSONEncoder().encode(page())
        let expectedPath = "/v1/catalog/" + pageID
        let client = EditorCommunityClient(server: server) { request in
            #expect(request.url?.path == expectedPath)
            return (data, try Self.response(for: request, status: 200))
        }
        #expect(try await client.game(id: pageID).title == "Moon Garden")
        let removed = EditorCommunityClient(server: server) { request in
            (Data(), try Self.response(for: request, status: 404))
        }
        await #expect(throws: EditorCommunityClient.CommunityError.self) { try await removed.game(id: pageID) }
    }
}
