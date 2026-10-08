import Testing
@testable import AdaText

struct TextMarkdownPluginTests {

    @Test
    func inlineMarkdown_removesDelimitersAndAppliesTraits() {
        let text = AttributedText(markdown: "Plain **bold** and *italic* and ***both***.")

        #expect(text.text == "Plain bold and italic and both.")
        #expect(attributes(in: text, at: "bold").fontTraits == .strong)
        #expect(attributes(in: text, at: "italic").fontTraits == .emphasis)
        #expect(attributes(in: text, at: "both").fontTraits.contains(.strong))
        #expect(attributes(in: text, at: "both").fontTraits.contains(.emphasis))
    }

    @Test
    func headers_applyExpectedScaleAndSpacing() {
        let text = AttributedText(markdown: """
        # Title

        ## Section

        ### Detail

        #### Minor
        """)

        #expect(text.text == "Title\n\nSection\n\nDetail\n\nMinor")

        let title = attributes(in: text, at: "Title")
        #expect(title.fontTraits == .strong)
        #expect(title.fontScale == 1.6)

        let section = attributes(in: text, at: "Section")
        #expect(section.fontTraits == .strong)
        #expect(section.fontScale == 1.35)

        let detail = attributes(in: text, at: "Detail")
        #expect(detail.fontTraits == .strong)
        #expect(detail.fontScale == 1.15)

        let minor = attributes(in: text, at: "Minor")
        #expect(minor.fontTraits == .strong)
        #expect(minor.fontScale == 1)
    }

    @Test
    func lineBreaks_renderAsNewlines() {
        let text = AttributedText(markdown: "first\nsecond  \nthird")

        #expect(text.text == "first\nsecond\nthird")
    }

    @Test
    func inlineCode_preservesLiteralContentAndAppliesCodeTrait() {
        let text = AttributedText(markdown: "Use `code **literal**` now")

        #expect(text.text == "Use code **literal** now")
        #expect(attributes(in: text, at: "code **literal**").fontTraits == .code)
    }

    @Test
    func unsupportedBlocks_degradeToReadableText() {
        let text = AttributedText(markdown: """
        - one
        - **two**
        """)

        #expect(text.text == "one\ntwo")
        #expect(attributes(in: text, at: "two").fontTraits == .strong)
    }

    private func attributes(in text: AttributedText, at substring: String) -> TextAttributeContainer {
        guard let range = text.text.range(of: substring) else {
            Issue.record("Missing substring \(substring)")
            return TextAttributeContainer()
        }

        return text.attributes(at: range.lowerBound)
    }
}
