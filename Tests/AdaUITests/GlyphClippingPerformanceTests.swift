@testable import AdaPlatform
@testable import AdaText
@testable import AdaUI
import Foundation
import Math
import Testing

@MainActor
struct GlyphClippingPerformanceTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADA_PERFORMANCE_BENCHMARK"] == "1"))
    func measureGlyphsInsideRoundedPanel() throws {
        let layout = TextLayoutManager()
        layout.setTextContainer(TextContainer(text: AttributedText("Editor performance text")))
        layout.fitToSize(Size(width: 600, height: 100))
        let glyph = try #require(layout.textLines.first?.first?.first)
        let tessellator = UITessellator()
        let path = RoundedRectangleShape(cornerRadius: 12).path(in: Rect(x: 0, y: 0, width: 1_000, height: 800))
        let polygons = tessellator.clipPathPolygons(path, transform: .identity)
        var vertexCount = 0
        let duration = ContinuousClock().measure {
            for index in 0..<30_000 {
                let transform = Transform3D(translation: [Float(30 + index % 40 * 10), -100, 0])
                vertexCount += tessellator.tessellateClippedGlyph(
                    glyph, transform: transform, textureIndex: 0, clipPolygons: polygons
                ).vertices.count
            }
        }
        print("PERFORMANCE rounded-panel 30000 glyphs: \(duration)")
        #expect(vertexCount == 120_000)
    }
}
