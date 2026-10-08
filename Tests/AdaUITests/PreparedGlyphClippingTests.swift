import AdaCorePipelines
@testable import AdaPlatform
import AdaText
@testable import AdaUI
import Math
import Testing

@MainActor
struct PreparedGlyphClippingTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func preparedClippingPreservesRoundedRotatedAndClockwiseMasks() throws {
        let tessellator = UITessellator()
        let path = RoundedRectangleShape(cornerRadius: 32).path(in: Rect(x: 0, y: 0, width: 500, height: 300))
        let rounded = tessellator.clipPathPolygons(path, transform: .identity)
        let rotated = tessellator.clipPathPolygons(path, transform: Transform3D(quat: Quat(axis: [0, 0, 1], angle: .pi / 6)))
        let masks = [rounded, rounded.map { Array($0.reversed()) }, rotated]
        var attributes = TextAttributeContainer()
        attributes.font = .system(size: 18)
        let layout = TextLayoutManager()
        layout.setTextContainer(TextContainer(
            text: AttributedText("M", attributes: attributes),
            textAlignment: .leading,
            lineBreakMode: .byCharWrapping,
            lineSpacing: 0,
            allowsShaping: false
        ))
        layout.fitToSize(Size(width: 100, height: 100))
        let glyph = try #require(layout.textLines.first?.first?.first)
        var accepted = 0
        var rejected = 0
        for mask in masks {
            let prepared = try #require(tessellator.prepareGlyphClip(mask))
            for x: Float in [-20, 0, 1, 15, 35, 120, 250, 470, 490, 510] {
                for y: Float in [-320, -300, -290, -260, -150, -40, -20, -2, 0, 20] {
                    let offset = Vector2(x - glyph.position.x, y - glyph.position.y)
                    guard tessellator.isGlyphFullyContained(glyph, transform: .identity, offset: offset, clip: prepared) else {
                        rejected += 1
                        continue
                    }
                    accepted += 1
                    let clipped = tessellator.tessellateClippedGlyph(
                        glyph, transform: .identity, textureIndex: 0, offset: offset, opacity: 0.6, clipPolygons: mask
                    )
                    var vertices: [GlyphVertexData] = []
                    var indices: [UInt32] = []
                    tessellator.appendGlyph(
                        glyph, transform: .identity, textureIndex: 0, offset: offset, opacity: 0.6, vertices: &vertices, indices: &indices
                    )
                    #expect(clipped.vertices.count == 4)
                    #expect(clipped.indices.count == 6)
                    #expect(indices.count == 6)
                    #expect(vertices.map(\.position) == clipped.vertices.map(\.position))
                    #expect(vertices.map(\.foregroundColor) == clipped.vertices.map(\.foregroundColor))
                    #expect(vertices.map(\.outlineColor) == clipped.vertices.map(\.outlineColor))
                    #expect(vertices.map(\.textureCoordinate) == clipped.vertices.map(\.textureCoordinate))
                }
            }
        }
        #expect(accepted > 30)
        #expect(rejected > 30)
    }

    @Test
    func emptyDegenerateAndMultipleMasksUseOriginalClipping() {
        let tessellator = UITessellator()
        #expect(tessellator.prepareGlyphClip([]) == nil)
        #expect(tessellator.prepareGlyphClip([[]]) == nil)
        #expect(tessellator.prepareGlyphClip([[Vector2(0, 0), Vector2(10, 0), Vector2(20, 0)]]) == nil)
        let rectangle: [Vector2] = [[0, 0], [100, 0], [100, -100], [0, -100]]
        #expect(tessellator.prepareGlyphClip([rectangle, rectangle]) == nil)
    }
}
