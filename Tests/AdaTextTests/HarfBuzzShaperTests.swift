@testable import AdaRender
import Testing
@testable import AdaText

struct HarfBuzzShaperTests {

    @Test
    func fontHandleCanResolveGlyphByGlyphIndex() throws {
        try Self.setupHeadlessRenderEngineIfNeeded()

        let font = FontResource.system(weight: .regular, emFontScale: 52)
        let scalarGlyph = try #require(font.handle.getGlyph(for: UnicodeScalar("A").value))

        #expect(font.handle.getGlyph(forGlyphIndex: scalarGlyph.glyphIndex) != nil)
    }

    @Test
    func textShaperShapesUTF8Text() throws {
        try Self.setupHeadlessRenderEngineIfNeeded()

        let font = FontResource.system(weight: .regular, emFontScale: 52)
        let shapedText = TextShaper.shape("Hello", font: font)

        #expect(!shapedText.isEmpty)
        #expect(shapedText.allSatisfy { $0.glyphIndex >= 0 })
    }

    @Test
    func textShaperReturnsPositionsInEmUnits() throws {
        try Self.setupHeadlessRenderEngineIfNeeded()

        let font = FontResource.system(weight: .regular, emFontScale: 52)
        let shapedText = TextShaper.shape("Hello", font: font)
        let totalAdvance = shapedText.reduce(0) { $0 + abs($1.xAdvance) }

        #expect(totalAdvance > 0)
        #expect(totalAdvance < Double(shapedText.count) * 2)
    }

    @Test
    func textShaperReordersDirectionalRunsUsingParagraphDirection() throws {
        try Self.setupHeadlessRenderEngineIfNeeded()

        let font = FontResource.system(weight: .regular, emFontScale: 52)
        let text = "abc אבג"
        let leftToRight = TextShaper.shape(text, font: font, writingDirection: .leftToRight)
        let rightToLeft = TextShaper.shape(text, font: font, writingDirection: .rightToLeft)

        #expect(leftToRight.first?.cluster == 0)
        #expect(rightToLeft.first?.cluster != 0)
        #expect(leftToRight.map(\.cluster) != rightToLeft.map(\.cluster))
    }

    private static func setupHeadlessRenderEngineIfNeeded() throws {
        guard unsafe RenderEngine.shared == nil else {
            return
        }

        unsafe RenderEngine.configurations.preferredBackend = .headless
        try RenderEngine.setupRenderEngine()
    }
}
