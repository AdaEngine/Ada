import Foundation
import MCP
import Testing

@testable import AdaEditor

@MainActor
@Suite("Editor web tools")
struct EditorWebToolTests {
    @Test("Shared inventory advertises external tools with download write semantics")
    func inventory() throws {
        let tools = EditorMobileAgentTools.tools()
        #expect(Set(tools.map(\.name)).count == tools.count)
        for name in ["editor.web.search", "editor.web.fetch", "editor.web.download"] {
            let tool = try #require(tools.first { $0.name == name })
            #expect(tool.annotations?.openWorldHint == true)
            #expect(tool.annotations?.readOnlyHint == (name != "editor.web.download"))
        }
    }

    @Test("Mobile dispatch returns readable HTML, decoded links, final URL and truncation")
    func fetch() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let html = """
        <html><head><title>Guide &amp; API</title><style>hidden CSS</style></head>
        <body><h1>Hello &#x1F600;</h1><script>hidden JS</script><p>Read &lt;Sprite&gt; &#65;.</p>
        <a href='/guide?a=1&amp;b=2'>Guide</a><a href='javascript:alert(1)'>Bad</a></body></html>
        """
        let final = try #require(URL(string: "https://example.com/docs/index"))
        let client = FixtureClient(data: Data(html.utf8), mimeType: "text/html", finalURL: final)
        let service = EditorMobileAgentToolService(projectURL: root, webClient: client)
        let result = await service.handle(name: "editor.web.fetch", arguments: ["url": "https://example.com/start", "maxCharacters": 20])
        #expect(result.ok)
        let value = try decode(result.payload)
        #expect(value["title"] as? String == "Guide & API")
        #expect(value["url"] as? String == final.absoluteString)
        #expect(value["truncated"] as? Bool == true)
        #expect(value["untrustedContent"] as? Bool == true)
        let links = try #require(value["links"] as? [[String: String]])
        #expect(links.count == 1)
        #expect(links.first?["url"] == "https://example.com/guide?a=1&b=2")
        let text = EditorWebHTML.text(html)
        #expect(text.contains("Hello 😀"))
        #expect(text.contains("<Sprite> A"))
        #expect(!text.contains("hidden JS"))
        #expect(!text.contains("hidden CSS"))
    }

    @Test("Search extracts genuine web results and preserves titles, URLs and snippets")
    func search() async throws {
        let html = """
        <a class="nav" href="/">Navigation</a>
        <div class="snippet dynamic-class" data-type="web"><div class="result-content"><a href="https://adaengine.org/docs"><div>Site name</div>
        <div class="title search-snippet-title">Ada &amp; Swift</div></a><div class="generic-snippet"><div class="content">Use <b>AdaScript</b>.</div></div></div></div>
        <div class="snippet" data-type="web"><a href="https://example.com/other"><div class="search-snippet-title">Other</div></a><div class="content">Second result</div></div>
        """
        let client = FixtureClient(data: Data(html.utf8), mimeType: "text/html")
        let service = EditorAgentWebToolService(client: client)
        let value = try await service.execute(name: "editor.web.search", arguments: ["query": "Ada Swift", "count": 1])
        let results = try #require(value["results"] as? [[String: String]])
        #expect(results.count == 1)
        #expect(results.first?["title"] == "Ada & Swift")
        #expect(results.first?["url"] == "https://adaengine.org/docs")
        #expect(results.first?["snippet"] == "Use AdaScript.")
        let request = try #require(await client.lastURL)
        #expect(request.host == "search.brave.com")
        #expect(URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "Ada Swift")
    }

    @Test("Provider challenges return a tool error rather than fake search results")
    func blockedSearch() async throws {
        let client = FixtureClient(data: Data("<html>Complete a captcha</html>".utf8), mimeType: "text/html")
        let service = EditorAgentWebToolService(client: client)
        await #expect(throws: EditorWebToolError.self) {
            _ = try await service.execute(name: "editor.web.search", arguments: ["query": "Swift"])
        }
    }

    @Test("Download saves exact binary bytes and preserves existing assets")
    func download() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data([0, 1, 2, 255])
        let client = FixtureClient(data: data, mimeType: "image/png")
        let service = EditorMobileAgentToolService(projectURL: root, webClient: client)
        let arguments: [String: Value] = ["url": "https://example.com/sprite.png", "destination": "Assets/Textures/sprite.png"]
        let result = await service.handle(name: "editor.web.download", arguments: arguments)
        #expect(result.ok)
        let saved = root.appendingPathComponent("Assets/Textures/sprite.png")
        #expect(try Data(contentsOf: saved) == data)
        #expect(try decode(result.payload)["bytes"] as? Int == 4)
        let duplicate = await service.handle(name: "editor.web.download", arguments: arguments)
        #expect(!duplicate.ok)
        #expect(duplicate.payload.contains("already exists"))
        #expect(try Data(contentsOf: saved) == data)
        #expect(await client.calls == 1)
    }

    @Test("Path traversal, project metadata and symlink escapes fail before networking")
    func paths() async throws {
        let root = try fixture()
        let outside = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Assets/escape"), withDestinationURL: outside)
        let client = FixtureClient(data: Data([1]), mimeType: "application/octet-stream")
        let service = EditorAgentWebToolService(projectURL: root, client: client)
        for destination in ["/tmp/file", "../file", "Assets/../../file", ".ada/project.json", "Sources/Game.ada", "Assets/escape/file", "Downloads/.secret", "Assets/", "Assets\\file"] {
            await #expect(throws: EditorWebToolError.self) {
                _ = try await service.execute(name: "editor.web.download", arguments: ["url": "https://example.com/file", "destination": .string(destination)])
            }
        }
        #expect(await client.calls == 0)
    }

    @Test("Size, binary text, URL and argument limits surface structured mobile errors")
    func limits() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = FixtureClient(data: Data([1, 2, 3]), mimeType: "application/octet-stream")
        let service = EditorMobileAgentToolService(projectURL: root, webClient: client)
        for (name, args) in [
            ("editor.web.fetch", ["url": Value.string("file:///etc/passwd")]),
            ("editor.web.fetch", ["url": Value.string("https://user:pass@example.com")]),
            ("editor.web.fetch", ["url": Value.string("http://127.0.0.1/file")]),
            ("editor.web.fetch", ["url": Value.string("https://example.com/file")]),
            ("editor.web.fetch", ["url": Value.string("https://example.com/file"), "maxCharacters": .int(0)]),
            ("editor.web.download", ["url": Value.string("https://example.com/file"), "destination": .string("Downloads/file"), "maxBytes": .int(2)]),
            ("editor.web.search", ["query": Value.string("   ")]),
            ("editor.web.search", ["query": Value.string("Swift"), "count": .double(2.5)]),
        ] {
            let result = await service.handle(name: name, arguments: args)
            #expect(!result.ok)
            #expect(result.payload.contains("error"))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Downloads/file").path))
    }

    @Test("Public network smoke reads and downloads using the production URLSession transport", .enabled(if: ProcessInfo.processInfo.environment["ADA_WEB_LIVE_SMOKE"] == "1"))
    func liveNetwork() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = EditorMobileAgentToolService(projectURL: root)
        let searched = await service.handle(name: "editor.web.search", arguments: ["query": "AdaEngine Swift", "count": 3])
        #expect(searched.ok, "\(searched.payload)")
        #expect(searched.payload.contains("adaengine.org"))
        let results = try #require(try decode(searched.payload)["results"] as? [[String: String]])
        #expect(results.contains { !($0["snippet"] ?? "").isEmpty })
        let fetched = await service.handle(name: "editor.web.fetch", arguments: ["url": "https://example.com"])
        #expect(fetched.ok, "\(fetched.payload)")
        #expect(fetched.payload.contains("Example Domain"))
        let downloaded = await service.handle(name: "editor.web.download", arguments: ["url": "https://example.com", "destination": "Downloads/example.html"])
        #expect(downloaded.ok, "\(downloaded.payload)")
        #expect(try String(contentsOf: root.appendingPathComponent("Downloads/example.html"), encoding: .utf8).contains("Example Domain"))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EditorWeb-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func decode(_ payload: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    }
}

private actor FixtureClient: EditorWebHTTPClient {
    let data: Data
    let mimeType: String
    let finalURL: URL?
    private(set) var calls = 0
    private(set) var lastURL: URL?

    init(data: Data, mimeType: String, finalURL: URL? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.finalURL = finalURL
    }

    func get(_ url: URL, maxBytes: Int) async throws -> EditorWebHTTPResponse {
        calls += 1
        lastURL = url
        return EditorWebHTTPResponse(data: data, url: finalURL ?? url, mimeType: mimeType, textEncodingName: "utf-8")
    }
}
