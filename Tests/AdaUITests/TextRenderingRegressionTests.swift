@testable import AdaPlatform
@testable import AdaText
@testable import AdaUI
import AdaUtils
import Math
import Testing

@MainActor
private final class GeometryRenderProbe {
    private(set) var count = 0

    func record<Content: View>(_ content: Content) -> Content {
        count += 1
        return content
    }
}

@MainActor
struct TextRenderingRegressionTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func textNodeDefersGlyphLayoutUntilMeasurement() {
        var environment = EnvironmentValues()
        environment.font = .system(size: 13)
        let node = TextViewNode(
            inputs: _ViewInputs(parentNode: nil, environment: environment),
            content: Text("Deferred text layout")
        )

        #expect(node.layoutManager.layoutRevision == 0)

        _ = node.sizeThatFits(.infinity)

        #expect(node.layoutManager.layoutRevision == 1)
    }

    @Test
    func unrelatedEnvironmentChangesReuseTextLayout() {
        var environment = EnvironmentValues()
        environment.font = .system(size: 13)
        let node = TextViewNode(
            inputs: _ViewInputs(parentNode: nil, environment: environment),
            content: Text("Stable text layout")
        )
        _ = node.sizeThatFits(.infinity)
        let revision = node.layoutManager.layoutRevision

        environment.accentColor = .red
        node.updateEnvironment(environment)
        _ = node.sizeThatFits(.infinity)

        #expect(node.layoutManager.layoutRevision == revision)
    }

    @Test
    func geometryReader_placesChildIntoAvailableBounds() {
        let tester = ViewTester {
            GeometryReader { _ in
                Color.red
                    .accessibilityIdentifier("geometry-content")
            }
        }
        .setSize(Size(width: 1200, height: 800))
        .performLayout()

        let contentNode = tester.findNodeByAccessibilityIdentifier("geometry-content")

        #expect(contentNode?.frame == Rect(x: 0, y: 0, width: 1200, height: 800))
    }

    @Test
    func geometryReader_childDrawsUsingContainerSize() {
        let tester = ViewTester {
            GeometryReader { _ in
                Color.red
            }
        }
        .setSize(Size(width: 1200, height: 800))
        .performLayout()

        let context = UIGraphicsContext()
        tester.containerView.viewTree.rootNode.draw(with: context)

        let hasVisibleQuad = context.getDrawCommands().contains { command in
            guard case let .drawQuad(transform, _, _) = command else {
                return false
            }
            return transform == Rect(x: 0, y: 0, width: 1200, height: 800).toTransform3D
        }

        #expect(hasVisibleQuad)
    }

    @Test
    func geometryReader_keepsFixedSizeChildAtTopLeadingOrigin() {
        let tester = ViewTester {
            GeometryReader { _ in
                Color.red
                    .frame(width: 100, height: 50)
                    .accessibilityIdentifier("geometry-fixed-child")
            }
        }
        .setSize(Size(width: 1200, height: 800))
        .performLayout()

        let childNode = tester.findNodeByAccessibilityIdentifier("geometry-fixed-child")

        #expect(childNode?.frame == Rect(x: 0, y: 0, width: 100, height: 50))
    }

    @Test
    func geometryReader_skipsContentRebuildWhenFrameIsUnchanged() async {
        let probe = GeometryRenderProbe()
        let tester = ViewTester {
            GeometryReader { _ in
                probe.record(
                    Color.red
                        .accessibilityIdentifier("geometry-content")
                )
            }
        }
        .setSize(Size(width: 1200, height: 800))
        .performLayout()

        let countAfterFirstLayout = probe.count
        tester.performLayout()

        #expect(probe.count == countAfterFirstLayout)

        tester
            .setSize(Size(width: 640, height: 480))
            .performLayout()

        #expect(probe.count == countAfterFirstLayout + 1)
    }

    @Test
    func wrappedTextReportsVisualLineHeight() {
        let tester = ViewTester {
            Text("This is a long chat message that should wrap into multiple visual rows.")
                .font(.system(size: 17))
                .frame(width: 120, alignment: .leading)
                .accessibilityIdentifier("wrapped-text")
        }
        .setSize(Size(width: 240, height: 240))
        .performLayout()

        let textNode = tester.findNodeByAccessibilityIdentifier("wrapped-text")

        #expect((textNode?.frame.height ?? 0) > 40)
    }

    @Test
    func fixedWidthFrameCentersTextWithoutRewrappingMeasuredWidth() {
        let tester = ViewTester {
            Text("Create new project")
                .font(.system(size: 15))
                .accessibilityIdentifier("button-title")
                .frame(width: 220, height: 48)
        }
        .setSize(Size(width: 220, height: 80))
        .performLayout()

        let textNode = tester.findNodeByAccessibilityIdentifier("button-title")
        #expect((textNode?.frame.width ?? 220) < 220)

        let context = UIGraphicsContext()
        tester.containerView.viewTree.rootNode.draw(with: context)
        let rows = drawnGlyphRowCenters(in: context.getDrawCommands())

        #expect(rows.count == 1)
    }

    @Test
    func fixedSquareFrameCentersSingleGlyphVisualBoundsHorizontally() throws {
        let frameWidth: Float = 38
        let tester = ViewTester {
            Text("↑")
                .font(.system(size: 28))
                .frame(width: frameWidth, height: frameWidth)
                .accessibilityIdentifier("centered-glyph")
        }
        .setSize(Size(width: frameWidth, height: frameWidth))
        .performLayout()

        let context = UIGraphicsContext()
        tester.containerView.viewTree.rootNode.draw(with: context)
        let bounds = try firstDrawnGlyphHorizontalBounds(in: context.getDrawCommands())
        let visualCenter = (bounds.minX + bounds.maxX) / 2

        #expect(abs(visualCenter - frameWidth / 2) <= 1)
    }

    @Test
    func unboundedTextMeasurementIsNotReusedFromClippedLayout() {
        let layoutManager = TextLayoutManager()
        layoutManager.setTextContainer(
            TextContainer(
                text: AttributedText("line one\nline two\nline three\nline four"),
                textAlignment: .leading,
                lineBreakMode: .byWordWrapping
            )
        )
        layoutManager.fitToSize(Size(width: 180, height: 18))

        let measured = Text.Proxy(layoutManager: layoutManager).sizeThatFits(.infinity)

        #expect(measured.height > 50)
    }

    @Test
    func flexibleFramedTextKeepsWrappedHeightInsideScrollView() {
        let longMessage = """
        Что сделал:
        Проанализировал текущий сайт: Swift Package + Ignite generator.
        Content/blog/*.md с frontmatter.
        Assets/ со статикой: styles/images/fonts/js/README.
        Принял архитектурное решение: Vite + TypeScript как build-платформа.
        Static SSG без SPA runtime: генерация реальных HTML-файлов для GitHub Pages.
        """

        let tester = ViewTester {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(markdown: longMessage)
                        .font(.system(size: 17))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("assistant-message")

                    Color.red
                        .frame(width: 100, height: 24)
                        .accessibilityIdentifier("next-row")
                }
            }
            .frame(width: 320, height: 180)
        }
        .setSize(Size(width: 320, height: 180))
        .performLayout()
        .performLayout()

        let messageNode = tester.findNodeByAccessibilityIdentifier("assistant-message")
        let nextRow = tester.findNodeByAccessibilityIdentifier("next-row")
        let messageMaxY = (messageNode?.absoluteFrame().maxY ?? 0)
        let nextMinY = (nextRow?.absoluteFrame().minY ?? 0)

        #expect((messageNode?.frame.height ?? 0) > 120)
        #expect(nextMinY >= messageMaxY + 12)
    }

    @Test
    func chatBubbleLikeVStackKeepsWrappedAssistantHeightInsideScrollView() {
        let longMessage = """
        Что сделал:
        Проанализировал текущий сайт: Swift Package + Ignite generator.
        **Content/blog/*.md** с frontmatter.
        **Assets/** со статикой: styles/images/fonts/js/README.
        Принял архитектурное решение: **Vite + TypeScript как build-платформа.**
        **Static SSG без SPA runtime:** генерация реальных HTML-файлов для GitHub Pages.
        """

        let tester = ViewTester {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Text("SLOPPY")
                                .font(.system(size: 13))
                            Text("->")
                                .font(.system(size: 11))
                        }

                        Color.clear
                            .frame(height: 1)

                        Text(markdown: longMessage)
                            .font(.system(size: 17))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("assistant-message-text")
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("assistant-bubble")

                    Color.red
                        .frame(width: 100, height: 24)
                        .accessibilityIdentifier("next-row")
                }
            }
            .frame(width: 360, height: 180)
        }
        .setSize(Size(width: 360, height: 180))
        .performLayout()
        .performLayout()

        let bubbleNode = tester.findNodeByAccessibilityIdentifier("assistant-bubble")
        let textNode = tester.findNodeByAccessibilityIdentifier("assistant-message-text")
        let nextRow = tester.findNodeByAccessibilityIdentifier("next-row")
        let bubbleMaxY = (bubbleNode?.absoluteFrame().maxY ?? 0)
        let nextMinY = (nextRow?.absoluteFrame().minY ?? 0)

        #expect((bubbleNode?.frame.height ?? 0) > 160)
        #expect((textNode?.frame.height ?? 0) > 120)
        #expect(nextMinY >= bubbleMaxY + 24)
    }

    @Test
    func wordWrappingMovesWholeWordToNextVisualRow() {
        let width = "MMMM W".size().width + 1

        let charRows = visualRowGlyphCounts(
            text: "MMMM WWWW",
            width: width,
            lineBreakMode: .byCharWrapping
        )
        let wordRows = visualRowGlyphCounts(
            text: "MMMM WWWW",
            width: width,
            lineBreakMode: .byWordWrapping
        )

        #expect((charRows.first ?? 0) > (wordRows.first ?? 0))
        #expect(wordRows.count > 1)
    }

    @Test
    func lineBreakModeModifierCanComeFromEnvironment() {
        let text = Text("Hello world")
        var environment = EnvironmentValues()
        environment.lineBreakMode = .byWordWrapping

        _ = text.storage.applyingEnvironment(environment)

        #expect(text.storage.lineBreakMode == .byWordWrapping)
    }

    @Test
    func textStringLiteralUsesLocalizedStringKey() {
        let text = Text("adaui.localized.literal", bundle: .module)
        let resolved = text.storage.applyingEnvironment(EnvironmentValues())

        #expect(resolved.text == "Localized AdaUI literal")
    }

    @Test
    func textPreservesLocalizedStringKeyBundle() {
        let key = LocalizedStringKey("adaui.localized.literal", bundle: .module)
        let text = Text(key)
        let resolved = text.storage.applyingEnvironment(EnvironmentValues())

        #expect(resolved.text == "Localized AdaUI literal")
    }

    @Test
    func textNodeRefreshesInheritedForegroundColorWhenEnvironmentChanges() throws {
        var environment = EnvironmentValues()
        environment.foregroundColor = .red
        let node = TextViewNode(
            inputs: _ViewInputs(parentNode: nil, environment: environment),
            content: Text("Theme title")
                .font(.system(size: 17))
        )

        node.place(
            in: Point(x: 100, y: 30),
            anchor: .center,
            proposal: ProposedViewSize(Size(width: 200, height: 60))
        )
        #expect(try firstDrawnGlyphColor(from: node) == .red)

        environment.foregroundColor = .blue
        node.updateEnvironment(environment)
        node.place(
            in: Point(x: 100, y: 30),
            anchor: .center,
            proposal: ProposedViewSize(Size(width: 200, height: 60))
        )

        #expect(try firstDrawnGlyphColor(from: node) == .blue)
    }

    @Test
    func multilineTextAlignmentShiftsWrappedRowsInsideAvailableWidth() {
        let width = "MMMM".size().width + 40
        let leadingMinX = firstRowMinX(text: "MMMM", width: width, alignment: .leading)
        let centerMinX = firstRowMinX(text: "MMMM", width: width, alignment: .center)
        let trailingMinX = firstRowMinX(text: "MMMM", width: width, alignment: .trailing)

        #expect(centerMinX > leadingMinX + 5)
        #expect(trailingMinX > centerMinX + 5)
    }

    @Test
    func multilineTextAlignmentModifierCanComeFromEnvironment() {
        let text = Text("Hello world")
        var environment = EnvironmentValues()
        environment.multilineTextAlignment = .trailing

        _ = text.storage.applyingEnvironment(environment)

        #expect(text.storage.multilineTextAlignment == .trailing)
    }

    @Test
    func multilineTextAlignmentDefaultsToLeading() {
        let text = Text("Hello world")
        let environment = EnvironmentValues()

        _ = text.storage.applyingEnvironment(environment)

        #expect(text.storage.multilineTextAlignment == .leading)
    }

    private func visualRowGlyphCounts(
        text: String,
        width: Float,
        lineBreakMode: LineBreakMode
    ) -> [Int] {
        let layoutManager = TextLayoutManager()
        layoutManager.setTextContainer(
            TextContainer(
                text: AttributedText(text),
                textAlignment: .leading,
                lineBreakMode: lineBreakMode
            )
        )
        layoutManager.fitToSize(Size(width: width, height: .infinity))

        var glyphCenters: [Float] = []
        for line in layoutManager.textLines {
            for run in line {
                for glyph in run {
                    glyphCenters.append((glyph.position.y + glyph.position.w) / 2)
                }
            }
        }

        let sortedCenters = glyphCenters.sorted(by: >)
        var rows: [(center: Float, count: Int)] = []

        for center in sortedCenters {
            guard let last = rows.last else {
                rows.append((center: center, count: 1))
                continue
            }

            if abs(last.center - center) <= 8 {
                rows[rows.count - 1] = (
                    center: ((last.center * Float(last.count)) + center) / Float(last.count + 1),
                    count: last.count + 1
                )
            } else {
                rows.append((center: center, count: 1))
            }
        }

        return rows.map(\.count)
    }

    private func firstRowMinX(
        text: String,
        width: Float,
        alignment: TextAlignment
    ) -> Float {
        let layoutManager = TextLayoutManager()
        layoutManager.setTextContainer(
            TextContainer(
                text: AttributedText(text),
                textAlignment: alignment,
                lineBreakMode: .byWordWrapping
            )
        )
        layoutManager.fitToSize(Size(width: width, height: .infinity))

        let glyphs = layoutManager.textLines.flatMap { line in
            line.flatMap { run in Array(run) }
        }

        return glyphs.map(\.position.x).min() ?? 0
    }

    private func firstDrawnGlyphColor(from node: TextViewNode) throws -> Color {
        let context = UIGraphicsContext()
        node.draw(with: context)

        for command in context.getDrawCommands() {
            if case let .drawGlyph(glyph, _, _) = command {
                return glyph.attributes.foregroundColor
            }
        }

        Issue.record("Expected text node to draw at least one glyph")
        throw TextRenderingRegressionTestError.missingGlyph
    }

    private func drawnGlyphRowCenters(in commands: [UIGraphicsContext.DrawCommand]) -> [Float] {
        var centers: [Float] = []

        for command in commands {
            guard case let .drawGlyph(glyph, transform, _) = command else {
                continue
            }

            centers.append(transform.w.y + ((glyph.position.y + glyph.position.w) / 2))
        }

        var rows: [Float] = []

        for center in centers.sorted(by: >) {
            guard let last = rows.last else {
                rows.append(center)
                continue
            }

            if abs(last - center) > 8 {
                rows.append(center)
            }
        }

        return rows
    }

    private func firstDrawnGlyphHorizontalBounds(
        in commands: [UIGraphicsContext.DrawCommand]
    ) throws -> (minX: Float, maxX: Float) {
        for command in commands {
            guard case let .drawGlyph(glyph, transform, _) = command else {
                continue
            }

            return (
                minX: transform.w.x + glyph.position.x,
                maxX: transform.w.x + glyph.position.z
            )
        }

        Issue.record("Expected at least one glyph draw command")
        throw TextRenderingRegressionTestError.missingGlyph
    }
}

private enum TextRenderingRegressionTestError: Error {
    case missingGlyph
}
