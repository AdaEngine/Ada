import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Hosted Ada AI internet tools", .serialized)
struct EditorCloudWebToolTests {
    @Test(arguments: [false, true])
    func bothHostsAdvertiseInternetTools(mobile: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudWeb-\(UUID())")
        let host = EditorCloudToolHost(projectURL: root, mobile: mobile ? EditorMobileAgentToolService(projectURL: root) : nil)
        let tools = try host.tools()
        #expect(Set(tools.map(\.name)).count == tools.count)
        #expect(tools.count <= 96)
        for name in ["editor_web_search", "editor_web_fetch", "editor_web_download"] {
            let tool = try #require(tools.first { $0.name == name })
            #expect(tool.readOnly == (name != "editor_web_download"))
            #expect(tool.definition["function"]["name"].string == name)
        }
    }

    @Test("Desktop cloud dispatch searches, reads and downloads into the owning project")
    func desktopDispatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudWeb-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Web tools", buildSystem: .adaScript), at: root)
        let editor = EditorViewModel(project: EditorProjectReference(name: "Web tools", path: root.path))
        EditorAgentMCPTools.shared.activate(editor)
        defer {
            EditorAgentMCPTools.shared.deactivate(editor)
            editor.stopProjectFileWatching()
        }
        let client = WebFixtureClient()
        let tools = try EditorCloudToolHost(projectURL: root, webClient: client).tools()
        let search = try #require(tools.first { $0.name == "editor_web_search" })
        let fetch = try #require(tools.first { $0.name == "editor_web_fetch" })
        let download = try #require(tools.first { $0.name == "editor_web_download" })
        let found = try await search.invoke(["query": "free game assets"])
        let payload = try JSONDecoder().decode(EditorCloudValue.self, from: Data(found.utf8))
        let result = try #require(payload["results"].array.first)
        #expect(result["title"].string == "Example assets")
        #expect(result["url"].string == "https://example.com/assets")
        #expect(payload["untrustedContent"] == .bool(true))
        let page = try await fetch.invoke(["url": "https://example.com/assets"])
        #expect(page.contains("Asset license"))
        _ = try await download.invoke(["url": "https://example.com/sprite.png", "destination": "Assets/Textures/sprite.png"])
        let destination = root.appendingPathComponent("Assets/Textures/sprite.png")
        #expect(try Data(contentsOf: destination) == Data([0, 1, 2, 255]))
        await #expect(throws: (any Error).self) {
            _ = try await download.invoke(["url": "https://example.com/sprite.png", "destination": "Assets/Textures/sprite.png"])
        }
        #expect(await client.calls == 3)
        EditorAgentMCPTools.shared.deactivate(editor)
        await #expect(throws: (any Error).self) { _ = try await search.invoke(["query": "another asset"]) }
        #expect(await client.calls == 3)
    }
}

private actor WebFixtureClient: EditorWebHTTPClient {
    private(set) var calls = 0

    func get(_ url: URL, maxBytes: Int) async throws -> EditorWebHTTPResponse {
        calls += 1
        let html: String
        if url.host == "search.brave.com" {
            html = """
            <div class="snippet" data-type="web"><a href="https://example.com/assets"><div class="search-snippet-title">Example assets</div></a>
            <div class="content">Free game assets and license details.</div></div>
            """
        } else if url.pathExtension == "png" {
            return .init(data: Data([0, 1, 2, 255]), url: url, mimeType: "image/png", textEncodingName: nil)
        } else {
            html = "<html><title>Asset license</title><body>Credit the artist.</body></html>"
        }
        return .init(data: Data(html.utf8), url: url, mimeType: "text/html", textEncodingName: "utf-8")
    }
}
