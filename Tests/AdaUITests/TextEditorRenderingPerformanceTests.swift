import AdaInput
@testable import AdaPlatform
import AdaText
@_spi(Internal) @testable import AdaUI
import AdaUtils
import Foundation
import Math
import Testing

@MainActor
struct TextEditorRenderingPerformanceTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func caretMetricsReuseAcrossColumnsColorsAndEdits() throws {
        var text = "\t    Wi 👩🏽‍💻 e\u{301}"
        let tester = ViewTester {
            TextEditor(text: Binding(get: { text }, set: { text = $0 }))
                .font(.system(size: 14))
                .frame(width: 500, height: 160)
        }
        .setSize(Size(width: 500, height: 160))
        .performLayout()
        let node = try #require(tester.sendMouseEvent(at: Point(100, 28), phase: .began) as? TextEditorViewNode)
        tester.sendMouseEvent(at: Point(100, 28), phase: .ended)
        let font = try #require(node.resolvedFontForRendering())
        let layout = try #require(node.cachedCaretLayout(for: text, font: font, pointSize: 14))
        let misses = node.caretLayoutCacheMisses
        #expect(layout.stops.count == text.count + 1)
        for column in 0...text.count {
            let x = node.caretXOffset(forColumn: column, in: text, font: font, pointSize: 14)
            #expect(x == layout.stops[column])
            #expect(node.closestColumn(toX: x, in: text, font: font, pointSize: 14) == column)
        }
        var environment = node.environment
        environment.foregroundColor = .red
        node.updateEnvironment(environment)
        #expect(node.cachedCaretLayout(for: text, font: font, pointSize: 14) === layout)
        #expect(node.caretLayoutCacheMisses == misses)

        var largerFont = font
        largerFont.pointSize *= 2
        let larger = try #require(node.cachedCaretLayout(for: text, font: largerFont, pointSize: 28))
        #expect(larger !== layout)
        #expect(abs(larger.xOffset(forColumn: text.count) - layout.xOffset(forColumn: text.count) * 2) < 0.01)

        let differentHeight = try #require(node.cachedCaretLayout(for: text, font: font, pointSize: 18))
        #expect(differentHeight !== layout)
        let differentFont = try #require(node.cachedCaretLayout(for: text, font: .system(size: 14, weight: .bold), pointSize: 14))
        #expect(differentFont !== layout)

        node.setSelection(to: text.count)
        tester.sendTextInput("W")
        let edited = try #require(node.cachedCaretLayout(for: node.text, font: font, pointSize: 14))
        #expect(edited !== layout)
        #expect(edited.characterCount == layout.characterCount + 1)
        #expect(edited.xOffset(forColumn: edited.characterCount) > layout.xOffset(forColumn: layout.characterCount))
        #expect(node.caretXOffset(forColumn: -1, in: "", font: font, pointSize: 14) == 0)
        #expect(node.caretXOffset(forColumn: 99, in: "ab", font: nil, pointSize: 14) == 2 * node.characterAdvance(for: 14))
    }

    @Test
    func indentationMarkersUseOneCaretLayoutPerLine() throws {
        let text = String(repeating: "    \t", count: 8) + "let value = 42"
        let tester = ViewTester {
            TextEditor(text: .constant(text), showsIndentationMarkers: true)
                .font(.system(size: 14))
                .frame(width: 1_000, height: 160)
        }
        .setSize(Size(width: 1_000, height: 160))
        .performLayout()
        let node = try #require(tester.sendMouseEvent(at: Point(100, 28), phase: .began) as? TextEditorViewNode)
        let font = try #require(node.resolvedFontForRendering())
        let accesses = node.caretLayoutCacheAccess
        var context = UIGraphicsContext()
        node.drawIndentationMarkers(
            in: &context,
            line: node.lines()[0],
            rowY: 0,
            pointSize: 14,
            font: font,
            showsIndentationGuides: true,
            showsTabMarkers: true,
            showsSpaceMarkers: true
        )
        #expect(node.caretLayoutCacheAccess == accesses + 1)
        #expect(context.getDrawCommands().count == 72) // 16 guides, 24 arrow segments, 32 space markers.
    }

    @Test
    func caretMetricCacheEvictsOldLinesAndRetainsRecentlyUsedLines() throws {
        let tester = ViewTester {
            TextEditor(text: .constant("old"))
                .font(.system(size: 14))
                .frame(width: 500, height: 160)
        }
        .setSize(Size(width: 500, height: 160))
        .performLayout()
        let node = try #require(tester.sendMouseEvent(at: Point(100, 28), phase: .began) as? TextEditorViewNode)
        let font = try #require(node.resolvedFontForRendering())
        let old = try #require(node.cachedCaretLayout(for: "old", font: font, pointSize: 14))
        let recent = try #require(node.cachedCaretLayout(for: "recent", font: font, pointSize: 14))
        for index in 0..<400 {
            _ = node.cachedCaretLayout(for: "line \(index)", font: font, pointSize: 14)
            #expect(node.cachedCaretLayout(for: "recent", font: font, pointSize: 14) === recent)
            #expect(node.caretLayoutCache.count <= 384)
        }
        #expect(node.cachedCaretLayout(for: "old", font: font, pointSize: 14) !== old)
    }

    @Test
    func styledGlyphCacheUpdatesForTextFontsTokensAndHover() throws {
        var text = "let value = 1"
        let tester = ViewTester {
            TextEditor(text: Binding(get: { text }, set: { text = $0 }))
                .font(.system(size: 14))
                .frame(width: 500, height: 160)
        }
        .setSize(Size(width: 500, height: 160))
        .performLayout()
        let node = try #require(tester.sendMouseEvent(at: Point(100, 28), phase: .began) as? TextEditorViewNode)
        tester.sendMouseEvent(at: Point(100, 28), phase: .ended)
        let font = try #require(node.resolvedFontForRendering())
        let bold = Font.system(size: 14, weight: .bold)
        node.tokenSpans = [TextEditorTokenSpan(line: 0, startColumn: 0, length: 3, color: .red, font: bold)]
        func draw(font: Font, color: Color, at point: Point = .zero) -> [Glyph] {
            var context = UIGraphicsContext()
            node.drawLineText(node.text, lineIndex: 0, font: font, fallbackColor: color, in: &context, at: point)
            return context.getDrawCommands().compactMap {
                if case let .drawGlyph(glyph, _, _) = $0 {
                    return glyph
                }
                return nil
            }
        }
        let initial = draw(font: font, color: .white)
        let cached = try #require(node.renderedLineCache[0])
        let misses = node.renderedLineCacheMisses
        #expect(initial.count == text.count)
        #expect(initial[0].attributes.font == bold)
        #expect(initial[0].attributes.foregroundColor == .red)
        #expect(initial[3].attributes.foregroundColor == .white)
        _ = draw(font: font, color: .white, at: Point(40, 50))
        #expect(node.renderedLineCache[0] === cached)
        #expect(node.renderedLineCacheMisses == misses)
        #expect(node.renderedLineCacheHits > 0)

        node.sourceInteraction = TextEditorSourceInteraction(hoveredRange: TextEditorSourceRange(
            start: TextEditorSourcePosition(line: 0, column: 4),
            end: TextEditorSourcePosition(line: 0, column: 9)
        ))
        var environment = node.environment
        environment.accentColor = .green
        node.updateEnvironment(environment)
        let hovered = draw(font: font, color: .white)
        #expect(hovered[4].attributes.foregroundColor == .green)
        #expect(hovered[0].attributes.foregroundColor == .red)
        node.sourceInteraction = nil
        #expect(draw(font: font, color: .white)[4].attributes.foregroundColor == .white)
        #expect(draw(font: font, color: .blue)[4].attributes.foregroundColor == .blue)

        node.tokenSpans[0].color = .blue
        node.tokenSpans[0].font = font
        let recolored = draw(font: font, color: .white)
        #expect(recolored[0].attributes.foregroundColor == .blue)
        #expect(recolored[0].attributes.font == font)
        let resized = draw(font: .system(size: 28), color: .white)
        #expect(resized[4].attributes.font.pointSize == 28)
        #expect((resized.last?.advanceX ?? 0) > (recolored.last?.advanceX ?? 0))

        node.setSelection(to: text.count)
        tester.sendTextInput("2")
        #expect(draw(font: font, color: .white).count == text.count)
        #expect(text == "let value = 12")
    }

    /// Opt in to a repeatable CPU drawing benchmark; this does not measure GPU/presentation time.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_TEXT_EDITOR_BENCHMARK"] == "1"))
    func indentedSourceScrollingBenchmark() throws {
        let text = (0..<160).map { index in
            String(repeating: " ", count: 24) + "let value\(index) = \(index) // " + String(repeating: "source text ", count: 8)
        }.joined(separator: "\n")
        let tokens = (0..<160).map { TextEditorTokenSpan(line: $0, startColumn: 24, length: 3, color: .blue) }
        let tester = ViewTester {
            TextEditor(text: .constant(text), tokenSpans: tokens, showsIndentationMarkers: true)
                .font(.system(size: 14))
                .frame(width: 1_000, height: 700)
        }
        .setSize(Size(width: 1_000, height: 700))
        .performLayout()
        let node = try #require(tester.sendMouseEvent(at: Point(100, 28), phase: .began) as? TextEditorViewNode)
        tester.sendMouseEvent(at: Point(100, 28), phase: .ended)
        _ = try #require(node.nearestScrollView())
        let root = tester.containerView.viewTree.rootNode
        let clock = ContinuousClock()
        var milliseconds: [Double] = []
        var glyphCount = 0
        for frame in 0..<48 {
            tester.sendMouseEvent(
                at: Point(400, 200),
                button: .scrollWheel,
                phase: .changed,
                scrollDelta: Point(0, frame % 24 < 12 ? -1 : 1)
            )
            let context = UIGraphicsContext()
            let start = clock.now
            root.draw(with: context)
            let duration = start.duration(to: clock.now).components
            if frame >= 12 {
                milliseconds.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
            }
            glyphCount = context.getDrawCommands().filter {
                if case .drawGlyph = $0 {
                    return true
                }
                return false
            }.count
        }
        milliseconds.sort()
        #expect(glyphCount > 1_000)
        print("TextEditor CPU draw benchmark: p50=\(milliseconds[milliseconds.count / 2]) ms, p95=\(milliseconds[Int(Double(milliseconds.count) * 0.95)]) ms, glyphs=\(glyphCount)")
    }
}
