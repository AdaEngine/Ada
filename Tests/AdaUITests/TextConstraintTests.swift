@testable import AdaPlatform
@testable import AdaText
@testable import AdaUI
import AdaUtils
import Math
import Testing

@MainActor
struct TextConstraintTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test(arguments: ["Colored sprite 30", "Colored sprite 31", "Colored sprite 32"])
    func idealSizeCanBeDrawnWithoutWrapping(_ title: String) throws {
        let node = makeNode(title)
        let measured = node.sizeThatFits(.unspecified)
        node.place(in: .zero, anchor: .topLeading, proposal: ProposedViewSize(measured))

        let context = UIGraphicsContext()
        node.draw(with: context)
        let glyphs = drawnGlyphs(context)
        #expect(glyphs.count == title.count)
        #expect(node.frame.height == measured.height)
        // All digits have the same baseline and height in this font.
        let last = try #require(glyphs.last)
        let previous = try #require(glyphs.dropLast().last)
        #expect(abs(last.position.y - previous.position.y) < 1)
    }

    @Test
    func tabularDigitsHaveEqualLayoutWidths() {
        let sizes = ["Colored sprite 30", "Colored sprite 31", "Colored sprite 32"].map {
            makeNode($0).sizeThatFits(.unspecified)
        }
        #expect(sizes[0] == sizes[1])
        #expect(sizes[1] == sizes[2])
    }

    @Test(arguments: [Float(60), 90, 140])
    func constrainedMeasurementIsStableWhenUsedForDrawing(_ width: Float) {
        let node = makeNode("Colored sprite 31 and another sprite")
        let measured = node.sizeThatFits(ProposedViewSize(width: width))
        #expect(measured.width <= width)
        let measuredGlyphs = node.layoutManager.textLines.flatMap { $0.flatMap { Array($0) } }

        node.place(in: .zero, anchor: .topLeading, proposal: ProposedViewSize(measured))
        let context = UIGraphicsContext()
        node.draw(with: context)
        let drawn = drawnGlyphs(context)
        #expect(drawn.count == measuredGlyphs.count)
        #expect(drawn.map(\.position.y) == measuredGlyphs.map(\.position.y))
    }

    @Test(arguments: [true, false], [LineBreakMode.byWordWrapping, .byCharWrapping])
    func lineLimitCountsWrappedRowsAcrossSourceLines(_ allowsShaping: Bool, _ mode: LineBreakMode) {
        var attributes = TextAttributeContainer()
        attributes.font = .system(size: 12, weight: .bold)
        var container = TextContainer(
            text: AttributedText("Colored sprite 31\nAnother sprite", attributes: attributes),
            textAlignment: .leading,
            lineBreakMode: mode,
            lineSpacing: 0,
            allowsShaping: allowsShaping
        )
        container.numberOfLines = 2
        let manager = TextLayoutManager()
        manager.setTextContainer(container)
        manager.fitToSize(Size(width: 60, height: .infinity))

        #expect(manager.boundingSize().height <= Float(attributes.font.lineHeight) * 2 + 0.01)
    }

    @Test
    func singleLineLimitIsRespectedDuringDrawing() {
        let node = makeNode("Colored sprite 31", lineLimit: 1)
        let measured = node.sizeThatFits(ProposedViewSize(width: 60))
        #expect(measured.width <= 60)
        #expect(measured.height <= Float(Font.system(size: 12, weight: .bold).lineHeight).rounded(.up))
        node.place(in: .zero, anchor: .topLeading, proposal: ProposedViewSize(measured))
        let context = UIGraphicsContext()
        node.draw(with: context)
        #expect(drawnGlyphs(context).count < "Colored sprite 31".count)
    }

    @Test
    func zeroAndFiniteHeightConstraintsAreRespected() {
        let node = makeNode("Colored sprite 31 and another sprite")
        #expect(node.sizeThatFits(.zero) == .zero)
        let measured = node.sizeThatFits(ProposedViewSize(width: 60, height: 20))
        #expect(measured.width <= 60)
        #expect(measured.height <= 20)
        let ideal = node.sizeThatFits(.unspecified)
        #expect(ideal.width > 60)
    }

    @Test(arguments: [Size(width: 1, height: 20), Size(width: 60, height: 1)])
    func constraintsSmallerThanOneGlyphClipDrawing(_ constraint: Size) {
        let node = makeNode("W", lineLimit: 1)
        let measured = node.sizeThatFits(ProposedViewSize(constraint))
        #expect(measured.width <= constraint.width)
        #expect(measured.height <= constraint.height)
        node.place(in: .zero, anchor: .topLeading, proposal: ProposedViewSize(measured))
        let context = UIGraphicsContext()
        node.draw(with: context)
        #expect(context.getDrawCommands().contains { command in
            guard case let .pushClipRect(rect) = command else {
                return false
            }
            return rect.width <= constraint.width && rect.height <= constraint.height
        })
    }

    @Test
    func alignmentDoesNotBecomeMeasuredPadding() {
        let sizes = [TextAlignment.leading, .center, .trailing].map { alignment in
            let node = TextViewNode(
                inputs: _ViewInputs(parentNode: nil, environment: EnvironmentValues()),
                content: Text("Colored sprite 31")
                    .font(.system(size: 12, weight: .bold))
                    .multilineTextAlignment(alignment)
            )
            return node.sizeThatFits(ProposedViewSize(width: 240))
        }
        #expect(sizes[0] == sizes[1])
        #expect(sizes[1] == sizes[2])
        #expect(sizes[0].width < 120)
    }

    @Test
    func symbolRetainsItsGlyphWhenMeasuredInsideSquare() {
        let node = TextViewNode(
            inputs: _ViewInputs(parentNode: nil, environment: EnvironmentValues()),
            content: Text("↑").font(.system(size: 28))
        )
        let ideal = node.sizeThatFits(.unspecified)
        let bounded = node.sizeThatFits(ProposedViewSize(width: 38, height: 38))
        node.place(in: .zero, anchor: .topLeading, proposal: ProposedViewSize(bounded))
        let context = UIGraphicsContext()
        node.draw(with: context)
        #expect(drawnGlyphs(context).count == 1, "ideal=\(ideal), bounded=\(bounded), frame=\(node.frame)")
    }

    @Test
    func hierarchyLabelKeepsAllDigitsInsideFixedHeightRow() throws {
        let tester = ViewTester {
            HStack(spacing: 8) {
                Color.gray.frame(width: 18, height: 18)
                Text("Colored sprite 31")
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
            .padding(.trailing, 30)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .setSize(Size(width: 200, height: 34))
        .performLayout()

        let context = UIGraphicsContext()
        tester.containerView.viewTree.rootNode.draw(with: context)
        let glyphs = drawnGlyphs(context)
        #expect(glyphs.count == "Colored sprite 31".count)
        let last = try #require(glyphs.last)
        let previous = try #require(glyphs.dropLast().last)
        #expect(abs(last.position.y - previous.position.y) < 1)
    }

    private func makeNode(_ title: String, lineLimit: Int? = nil) -> TextViewNode {
        TextViewNode(
            inputs: _ViewInputs(parentNode: nil, environment: EnvironmentValues()),
            content: Text(title)
                .font(.system(size: 12, weight: .bold))
                .lineLimit(lineLimit)
        )
    }

    private func drawnGlyphs(_ context: UIGraphicsContext) -> [Glyph] {
        context.getDrawCommands().compactMap { command in
            guard case let .drawGlyph(glyph, _, _) = command else {
                return nil
            }
            return glyph
        }
    }
}
