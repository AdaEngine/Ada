import Foundation
import Testing

@testable import AdaRender
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
    func loadedFontKeepsShapingWhenItsSourceIsRemoved() throws {
        try Self.setupHeadlessRenderEngineIfNeeded()

        let systemFont = FontResource.system(weight: .regular, emFontScale: 52)
        let source = try #require(systemFont.handle.fontPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        let text = "office"
        let font = try #require(FontResource.custom(
            fontPath: copy,
            includeDefaultCharset: false,
            additionalCodepoints: text.unicodeScalars.map(\.value)
        ))

        let expected = TextShaper.shape(text, font: font)
        try #require(!expected.isEmpty)
        try FileManager.default.removeItem(at: copy)

        #expect(TextShaper.shape(text, font: font) == expected)
    }

    @Test
    func shapingRetriesAfterTheFontSourceBecomesAvailable() throws {
        try Self.setupHeadlessRenderEngineIfNeeded()

        let systemFont = FontResource.system(weight: .regular, emFontScale: 52)
        let source = try #require(systemFont.handle.fontPath)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(source.pathExtension)
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: source, to: copy)

        let font = try #require(FontResource.custom(
            fontPath: copy,
            includeDefaultCharset: false,
            additionalCodepoints: [65]
        ))
        try FileManager.default.removeItem(at: copy)
        #expect(TextShaper.shape("A", font: font).isEmpty)

        try FileManager.default.copyItem(at: source, to: copy)
        let expected = TextShaper.shape("A", font: systemFont)
        try #require(!expected.isEmpty)
        #expect(TextShaper.shape("A", font: font) == expected)
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
