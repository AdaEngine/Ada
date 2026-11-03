import Markdown

/// A Markdown block with inline styles preserved for native block layout.
public struct TextMarkdownBlock: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        case text(AttributedText)
        case code(String, language: String?)
        case quote([TextMarkdownBlock])
        case table(header: [AttributedText], rows: [[AttributedText]])
        case divider
    }

    public let content: Content
    private let source: String

    private init(_ markup: any Markup) {
        source = markup.format()
        switch markup {
        case let code as CodeBlock:
            content = .code(code.code, language: code.language)
        case let quote as BlockQuote:
            content = .quote(quote.children.map { Self($0) })
        case let table as Table:
            content = .table(
                header: table.head.children.map { Self.inline($0) },
                rows: table.body.children.map { row in row.children.map { Self.inline($0) } }
            )
        case is ThematicBreak:
            content = .divider
        default:
            content = .text(Self.inline(markup))
        }
    }

    /// Parses a document, reusing unchanged blocks from its previous revision.
    /// Keep the previous revision per message, rather than retaining an unbounded global cache.
    public static func parse(_ markdown: String, reusing previous: [Self] = []) -> [Self] {
        let cached = Dictionary(previous.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
        return Document(parsing: markdown).children.map { markup in
            cached[markup.format()] ?? Self(markup)
        }
    }

    private static func inline(_ markup: any Markup) -> AttributedText {
        var renderer = MarkdownAttributedTextRenderer(attributes: .init(), options: .init())
        renderer.visit(markup)
        return renderer.result
    }
}
