@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Agent logos")
struct EditorAgentIconTests {
    @Test("common agents have bundled logos without network", arguments: ["codex-acp", "claude-acp", "gemini", "opencode", "amp-acp", "sloppy-acp"])
    func bundledLogo(id: String) throws {
        let image = try #require(EditorAgentIconStore.bundledImage(id: id))
        #expect(image.width > 0 && image.height > 0)
        #expect(image.data.enumerated().contains { offset, byte in offset % 4 == 3 && byte > 0 })
    }

    @Test("unknown agents keep a fallback without invalid resource lookup")
    func missingLogo() {
        #expect(EditorAgentIconStore.bundledImage(id: "unknown-agent") == nil)
        #expect(EditorAgentIconStore.bundledImage(id: "../codex-acp") == nil)
    }

    @Test("installed metadata remains compatible with records without an icon")
    func installedMetadata() throws {
        let original = EditorInstalledAgent(id: "codex-acp", name: "Codex", version: "1", target: .init(command: "/codex-acp"))
        #expect(try JSONDecoder().decode(EditorInstalledAgent.self, from: JSONEncoder().encode(original)).icon == nil)
        var branded = original
        branded.icon = "https://example.com/codex.svg"
        #expect(try JSONDecoder().decode(EditorInstalledAgent.self, from: JSONEncoder().encode(branded)).icon == branded.icon)
    }

    #if os(macOS)
        @Test("SVG becomes a theme-tintable mask with transparent edges and preserved aspect ratio")
        func svgMask() throws {
            let data = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"16\"><rect width=\"32\" height=\"16\" fill=\"currentColor\"/></svg>".utf8)
            let image = try #require(EditorAgentIconStore.decodeIcon(data))
            #expect(image.width == 64 && image.height == 64)
            let center = image.getPixel(x: 32, y: 32)
            #expect(center.alpha > 0.99)
            #expect(center.red == 1 && center.green == 1 && center.blue == 1)
            #expect(image.getPixel(x: 32, y: 0).alpha == 0)
            #expect(EditorAgentIconStore.decodeIcon(Data("invalid SVG".utf8)) == nil)
        }
    #endif
}
