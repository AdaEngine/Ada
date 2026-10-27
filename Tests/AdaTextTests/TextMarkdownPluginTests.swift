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
    func unorderedLists_preserveMarkersAndTraits() {
        let text = AttributedText(markdown: """
        - one
        - **two**
        """)

        #expect(text.text == "• one\n• two")
        #expect(attributes(in: text, at: "two").fontTraits == .strong)
    }

    @Test func nestedAndOrderedListsPreserveStructure() {
        let text = AttributedText(markdown: "3. first\n4. second\n   - child")
        #expect(text.text == "3. first\n4. second\n  • child")
    }

    @Test func taskListsAndQuotesRemainReadable() {
        let text = AttributedText(markdown: "- [x] done\n- [ ] pending\n\n> quoted **text**")
        #expect(text.text == "• [x] done\n• [ ] pending\n\n> quoted text")
        #expect(attributes(in: text, at: "text").fontTraits == .strong)
    }

    @Test func tableCellsAndRowsDoNotRunTogether() {
        let text = AttributedText(markdown: "| Name | State |\n| --- | --- |\n| A | Done |\n| B | Ready |")
        #expect(text.text == "Name | State\nA | Done\nB | Ready")
    }

    @Test func linksKeepTheirDestinationWithoutExposingMarkup() {
        let text = AttributedText(markdown: "Read [AdaEngine](https://adaengine.org/docs).")
        #expect(text.text == "Read AdaEngine.")
        #expect(attributes(in: text, at: "AdaEngine").link == "https://adaengine.org/docs")
    }

    private func attributes(in text: AttributedText, at substring: String) -> TextAttributeContainer {
        guard let range = text.text.range(of: substring) else {
            Issue.record("Missing substring \(substring)")
            return TextAttributeContainer()
        }

        return text.attributes(at: range.lowerBound)
    }
}
