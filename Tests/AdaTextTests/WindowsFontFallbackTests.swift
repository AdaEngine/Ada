#if os(Windows)
@testable import AdaRender
import Testing
@testable import AdaText

@Suite("Windows symbol fallback", .serialized)
@MainActor
struct WindowsFontFallbackTests {
    init() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
    }

    @Test("Unicode symbols keep their glyphs in regular and bold text", arguments: [false, true])
    func symbolLayout(strong: Bool) throws {
        var attributes = TextAttributeContainer()
        attributes.font = .system(size: 20, weight: strong ? .bold : .regular)
        let primary = attributes.font.fontResource
        for symbol in "→←⇒✓".unicodeScalars {
            #expect(primary.handle.getGlyph(for: symbol.value) == nil)
            let fallback = try #require(FontResource.fallback(for: symbol, baseFont: primary))
            #expect(fallback.handle.getGlyph(for: symbol.value) != nil)
            let source = "Убежище \(symbol) вылазка"
            for mode: LineBreakMode in [.byWordWrapping, .byCharWrapping] {
                for shaping in [false, true] {
                    let manager = TextLayoutManager()
                    var container = TextContainer(text: AttributedText(source, attributes: attributes), lineBreakMode: mode)
                    container.allowsShaping = shaping
                    manager.setTextContainer(container)
                    manager.fitToSize(.infinity)
                    let glyph = try #require(manager.textLines.flatMap(\.runs).flatMap(\.glyphs).first { glyph in
                        glyph.sourceRange.map { String(source[$0]) == String(symbol) } == true
                    })
                    #expect(glyph.textureAtlas === fallback.handle.atlasTexture)
                }
            }
        }
    }

    @Test("Neighboring arrows reuse their atlas and unsupported scalars remain missing")
    func atlasReuse() throws {
        let base = FontResource.system()
        let right = try #require(FontResource.fallback(for: "→", baseFont: base))
        let left = try #require(FontResource.fallback(for: "←", baseFont: base))
        #expect(right === left)
        #expect(FontResource.fallback(for: "→", baseFont: base) === right)
        #expect(FontResource.fallback(for: "\u{10FFFF}", baseFont: base) == nil)
    }
}
#endif
