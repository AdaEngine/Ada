@testable import AdaEditor
import AdaEngine
import Foundation
import Testing

struct EditorGameScreenshotMarkupTests {
    @Test
    func marksKeepTheirImageCoordinatesWhenCanvasSizeChanges() {
        let first = EditorGameScreenshotMarkup.normalized(Point(50, 25), in: Size(width: 200, height: 100))
        let resized = EditorGameScreenshotMarkup.normalized(Point(100, 50), in: Size(width: 400, height: 200))
        #expect(first == resized)
        #expect(first == Point(0.25, 0.25))
        #expect(EditorGameScreenshotMarkup.normalized(Point(90, 155), in: Rect(x: 40, y: 130, width: 200, height: 100)) == first)
        #expect(EditorGameScreenshotMarkup.normalized(Point(-10, 250), in: Size(width: 200, height: 100)) == Point(0, 1))
    }

    #if canImport(CoreGraphics) && canImport(ImageIO)
    @Test
    func pngIncludesOriginalFrameAndMarksAtTheCorrectVerticalPosition() async throws {
        let original = Image(width: 200, height: 100, color: .blue)
        let markup = EditorGameScreenshotMarkup(strokes: [[Point(0.1, 0.2), Point(0.9, 0.2)]])
        let data = try await markup.pngData(for: original)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let result = try Image(contentsOf: url)
        #expect(result.width == 200)
        #expect(result.height == 100)
        #expect(result.getPixel(x: 100, y: 20).red > 0.9)
        #expect(result.getPixel(x: 100, y: 80).blue > 0.9)

        let cleared = try await EditorGameScreenshotMarkup().pngData(for: original)
        try cleared.write(to: url)
        #expect(try Image(contentsOf: url).getPixel(x: 100, y: 20).blue > 0.9)
    }
    #endif
}
