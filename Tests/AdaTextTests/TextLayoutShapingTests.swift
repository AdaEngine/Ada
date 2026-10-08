@testable import AdaRender
import Testing
@testable import AdaText

struct TextLayoutShapingTests {

    @Test
    func layoutUsesHarfBuzzGlyphSequenceForLigatureText() throws {
        try Self.setupHeadlessRenderEngineIfNeeded()

        var attributes = TextAttributeContainer()
        attributes.font = .system(size: 32)
        let text = AttributedText("fi", attributes: attributes)
        let shapedGlyphs = TextShaper.shape(text.text, font: attributes.font.fontResource)

        #expect(shapedGlyphs.count == 1)

        let layoutManager = TextLayoutManager()
        layoutManager.setTextContainer(
            TextContainer(
                text: text,
                textAlignment: .leading,
                lineBreakMode: .byCharWrapping
            )
        )
        layoutManager.fitToSize(.infinity)

        let line = try #require(layoutManager.textLines.first)
        let run = try #require(line.runs.first)
        #expect(run.count == shapedGlyphs.count)
    }

    @Test
    func wordWrappingStillShapesCharactersWithinEachWord() throws {
        try Self.setupHeadlessRenderEngineIfNeeded()

        var attributes = TextAttributeContainer()
        attributes.font = .system(size: 32)
        let text = AttributedText("fi", attributes: attributes)

        let layoutManager = TextLayoutManager()
        layoutManager.setTextContainer(
            TextContainer(
                text: text,
                textAlignment: .leading,
                lineBreakMode: .byWordWrapping
            )
        )
        layoutManager.fitToSize(.infinity)

        let line = try #require(layoutManager.textLines.first)
        let run = try #require(line.runs.first)
        #expect(run.count == 1)
    }

    @Test
    func latinWordFitsOnSingleVisualLineAtNormalWidth() throws {
        try Self.setupHeadlessRenderEngineIfNeeded()

        var attributes = TextAttributeContainer()
        attributes.font = .system(size: 11)
        let text = AttributedText("Problems", attributes: attributes)

        let layoutManager = TextLayoutManager()
        layoutManager.setTextContainer(
            TextContainer(
                text: text,
                textAlignment: .leading,
                lineBreakMode: .byWordWrapping
            )
        )
        layoutManager.fitToSize(.init(width: 56, height: .infinity))

        let expectedLineHeight = Float(attributes.font.lineHeight)
        #expect(layoutManager.boundingSize().height <= expectedLineHeight * 1.1)
    }

    private static func setupHeadlessRenderEngineIfNeeded() throws {
        guard unsafe RenderEngine.shared == nil else {
            return
        }

        unsafe RenderEngine.configurations.preferredBackend = .headless
        try RenderEngine.setupRenderEngine()
    }
}
