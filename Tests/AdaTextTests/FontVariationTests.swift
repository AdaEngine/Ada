import Foundation
import Testing
@testable import AdaText

struct FontVariationTests {

    @Test
    func prebuiltAtlasFileNameIncludesVariationAxes() {
        let regular = FontResource.prebuiltAtlasFileName(
            fontFileName: "Variable.ttf",
            emFontScale: 48,
            variations: [.weight(400)]
        )
        let bold = FontResource.prebuiltAtlasFileName(
            fontFileName: "Variable.ttf",
            emFontScale: 48,
            variations: [.weight(700)]
        )

        #expect(regular != bold)
    }

    @Test
    func customAtlasPrebuildsWithVariationAxes() throws {
        let fontPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Editor/Sources/AdaEditor/Assets/Fonts/MaterialSymbolsRounded-Regular.ttf")

        let wasPrebuilt = FontResource.prebuildCustomAtlas(
            fontPath: fontPath,
            emFontScale: 48,
            includeDefaultCharset: false,
            additionalCodepoints: "arrow_upward".unicodeScalars.map(\.value),
            variations: [
                .weight(700),
                FontVariationAxis(tag: "FILL", value: 1),
                FontVariationAxis(tag: "opsz", value: 24),
            ]
        )

        #expect(wasPrebuilt)
    }
}
