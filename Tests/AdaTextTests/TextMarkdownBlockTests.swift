import Testing
@testable import AdaText

struct TextMarkdownBlockTests {
    @Test func preservesBlockStructureAndInlineStyles() throws {
        let blocks = TextMarkdownBlock.parse("""
        # Title

        - **Bold**
        - [Docs](https://adaengine.org)

        ```swift
        let literal = "**text**"
        ```

        > A *quote*

        | Name | State |
        | --- | --- |
        | A | **Ready** |

        ---
        """)
        #expect(blocks.count == 6)
        guard case let .text(heading) = blocks[0].content,
              case let .text(list) = blocks[1].content,
              case let .code(code, language) = blocks[2].content,
              case let .quote(quote) = blocks[3].content,
              case let .table(header, rows) = blocks[4].content else {
            Issue.record("Expected heading, list, code, quote and table blocks")
            return
        }
        #expect(heading.text == "Title")
        #expect(heading.attributes(at: heading.startIndex).fontScale == 1.6)
        #expect(list.text == "• Bold\n• Docs")
        #expect(code == "let literal = \"**text**\"\n")
        #expect(language == "swift")
        #expect(quote.count == 1)
        #expect(header.map(\.text) == ["Name", "State"])
        #expect(rows.first?.map(\.text) == ["A", "Ready"])
        #expect(blocks[5].content == .divider)
    }

    @Test func incompleteFencesAndUnicodeSurviveStreaming() throws {
        let first = TextMarkdownBlock.parse("Привет 👋\n\n```ada\nlet value = 1")
        let next = TextMarkdownBlock.parse("Привет 👋\n\n```ada\nlet value = 123\n```", reusing: first)
        #expect(first[0] == next[0])
        guard case let .code(code, language) = next[1].content else {
            Issue.record("Expected a code block")
            return
        }
        #expect(code == "let value = 123\n")
        #expect(language == "ada")
    }
}
