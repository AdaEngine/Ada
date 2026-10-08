@testable import AdaEditor
@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing

@MainActor
@Suite("Community AdaUI", .serialized)
struct EditorCommunityUITests {
    private let firstID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let secondID = "cccccccc-cccc-cccc-cccc-cccccccccccc"

    private func page(id: String, title: String, likes: Int64) -> EditorCloudValue {
        [
            "id": .string(id), "title": .string(title), "description": "A world from another player", "tags": ["Adventure"],
            "published": true, "likes": .integer(likes),
            "publication": ["mode": "ugc", "approved": true, "releaseId": "release", "url": "https://game.example.com/"]
        ]
    }

    private func client() throws -> EditorCommunityClient {
        let pages = [page(id: firstID, title: "Moon Garden", likes: 12), page(id: secondID, title: "Star Runner", likes: 42)]
        let list = try JSONEncoder().encode(EditorCloudValue.array(pages))
        let detail = try JSONEncoder().encode(pages[0])
        return EditorCommunityClient(server: try #require(URL(string: "https://cloud.example.com"))) { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (url.path == "/v1/catalog" ? list : detail, response)
        }
    }

    private func container<Content: View>(_ content: Content) -> UIContainerView<Content> {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let worlds = AppWorlds(main: World(name: "CommunityUITests"))
            RenderWorldPlugin().setup(in: worlds)
        }
        let container = UIContainerView(rootView: content)
        container.frame = Rect(x: 0, y: 0, width: 640, height: 900)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        return container
    }

    @Test func sortAndSearchUseSharedControls() async throws {
        let model = EditorCommunityModel(client: try client())
        await model.reload()
        let view = container(EditorCommunityView(model: model).theme(.adaEditor))
        _ = try view.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Community.Sort.Popular"))
        #expect(model.popularFirst)
        #expect(model.results.first?.title == "Star Runner")
        _ = try view.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Community.Search"))
        view.onTextInputEvent(TextInputEvent(window: .empty, text: "moon", action: .insert, time: 0))
        #expect(model.query == "moon")
        #expect(model.results.map(\.title) == ["Moon Garden"])
    }

    @Test func cardOpensSharedDetailNavigation() async throws {
        let model = EditorCommunityModel(client: try client())
        await model.reload()
        let view = container(EditorCommunityView(model: model).theme(.adaEditor))
        _ = try view.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Community.Game." + firstID))
        for _ in 0..<3 {
            await Task.yield()
            view.update(1 / 60)
            view.layoutIfNeeded()
        }
        _ = try view.uiNode(matching: .accessibilityIdentifier("AdaEditor.Community.Detail"))
        _ = try view.uiNode(matching: .accessibilityIdentifier("AdaEditor.Community.Play"))
    }

    @Test func playRechecksPublicationBeforePlatformAction() async throws {
        @MainActor final class Opened { var urls: [URL] = [] }
        let opened = Opened()
        let model = EditorCommunityModel(client: try client())
        await model.reload()
        let game = try #require(model.games.first)
        let view = container(EditorCommunityDetailView(game: game, client: model.client) { url in
            opened.urls.append(url)
            return true
        }.theme(.adaEditor))
        _ = try view.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Community.Play"))
        for _ in 0..<100 {
            if !opened.urls.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(opened.urls == [game.playURL])
    }
}
