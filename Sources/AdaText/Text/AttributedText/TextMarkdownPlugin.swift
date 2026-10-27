//
//  TextMarkdownPlugin.swift
//  AdaEngine
//
//  Created by Codex on 4/30/26.
//

import Markdown

/// Options used when converting Markdown into ``AttributedText``.
public struct TextMarkdownOptions: Hashable, Sendable {
    public var blockSeparator: String
    public var softBreak: String
    public var hardBreak: String
    public var headerScales: [Int: Double]

    public init(
        blockSeparator: String = "\n\n",
        softBreak: String = "\n",
        hardBreak: String = "\n",
        headerScales: [Int: Double] = [
            1: 1.6,
            2: 1.35,
            3: 1.15,
        ]
    ) {
        self.blockSeparator = blockSeparator
        self.softBreak = softBreak
        self.hardBreak = hardBreak
        self.headerScales = headerScales
    }

    func headerScale(for level: Int) -> Double {
        self.headerScales[level] ?? 1
    }
}

/// Converts Markdown into AdaText attributed text.
public enum TextMarkdownPlugin {
    public static func parse(
        _ markdown: String,
        attributes: TextAttributeContainer = TextAttributeContainer(),
        options: TextMarkdownOptions = TextMarkdownOptions()
    ) -> AttributedText {
        let document = Document(parsing: markdown)
        var renderer = MarkdownAttributedTextRenderer(attributes: attributes, options: options)
        renderer.visit(document)
        return renderer.result
    }
}

private struct MarkdownAttributedTextRenderer: MarkupVisitor {
    typealias Result = Void

    private(set) var result: AttributedText = ""
    private var attributes: TextAttributeContainer
    private let options: TextMarkdownOptions
    private var listDepth = 0

    init(attributes: TextAttributeContainer, options: TextMarkdownOptions) {
        self.attributes = attributes
        self.options = options
    }

    mutating func defaultVisit(_ markup: Markup) {
        self.renderChildren(of: markup)
    }

    mutating func visitDocument(_ document: Document) {
        self.renderChildren(of: document, separator: self.options.blockSeparator)
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        self.renderChildren(of: paragraph)
    }

    mutating func visitHeading(_ heading: Heading) {
        let headerScale = self.options.headerScale(for: heading.level)
        self.pushAttributes { attributes in
            attributes.fontTraits.insert(.strong)
            attributes.fontScale *= headerScale
        }
        self.renderChildren(of: heading)
        self.popAttributes()
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        renderList(unorderedList, start: nil)
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        renderList(orderedList, start: Int(orderedList.startIndex))
    }

    mutating func visitListItem(_ listItem: ListItem) {
        if let checkbox = listItem.checkbox { append(checkbox == .checked ? "[x] " : "[ ] ") }
        for (index, child) in listItem.children.enumerated() {
            if index > 0 { append(options.hardBreak) }
            visit(child)
        }
    }

    private mutating func renderList(_ list: Markup, start: Int?) {
        listDepth += 1
        for (index, item) in list.children.enumerated() {
            if index > 0 { append(options.hardBreak) }
            append(String(repeating: "  ", count: listDepth - 1))
            append(start.map { "\($0 + index). " } ?? "• ")
            visit(item)
        }
        listDepth -= 1
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        append("> ")
        renderChildren(of: blockQuote, separator: options.blockSeparator)
    }

    mutating func visitThematicBreak(_: ThematicBreak) { append("--------") }

    mutating func visitLink(_ link: Link) {
        pushAttributes { $0.link = link.destination }
        renderChildren(of: link)
        popAttributes()
    }

    mutating func visitImage(_ image: Markdown.Image) {
        append("[Image: ")
        renderChildren(of: image)
        append("]")
    }

    mutating func visitTable(_ table: Table) { renderChildren(of: table, separator: options.hardBreak) }
    mutating func visitTableHead(_ head: Table.Head) {
        pushAttributes { $0.fontTraits.insert(.strong) }
        renderChildren(of: head, separator: " | ")
        popAttributes()
    }
    mutating func visitTableBody(_ body: Table.Body) { renderChildren(of: body, separator: options.hardBreak) }
    mutating func visitTableRow(_ row: Table.Row) { renderChildren(of: row, separator: " | ") }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        self.pushAttributes { attributes in
            attributes.fontTraits.insert(.code)
        }
        self.append(codeBlock.code)
        self.popAttributes()
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        self.pushAttributes { attributes in
            attributes.fontTraits.insert(.code)
        }
        self.append(inlineCode.code)
        self.popAttributes()
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        self.pushAttributes { attributes in
            attributes.fontTraits.insert(.emphasis)
        }
        self.renderChildren(of: emphasis)
        self.popAttributes()
    }

    mutating func visitStrong(_ strong: Strong) {
        self.pushAttributes { attributes in
            attributes.fontTraits.insert(.strong)
        }
        self.renderChildren(of: strong)
        self.popAttributes()
    }

    mutating func visitLineBreak(_: LineBreak) {
        self.append(self.options.hardBreak)
    }

    mutating func visitSoftBreak(_: SoftBreak) {
        self.append(self.options.softBreak)
    }

    mutating func visitText(_ text: Markdown.Text) {
        self.append(text.string)
    }

    private mutating func renderChildren(of markup: Markup, separator: String? = nil) {
        var needsSeparator = false

        for child in markup.children {
            if needsSeparator, let separator {
                self.append(separator)
            }

            let lengthBeforeRender = self.result.text.count
            self.visit(child)
            needsSeparator = self.result.text.count > lengthBeforeRender
        }
    }

    private var attributeStack: [TextAttributeContainer] = []

    private mutating func pushAttributes(_ update: (inout TextAttributeContainer) -> Void) {
        self.attributeStack.append(self.attributes)
        update(&self.attributes)
    }

    private mutating func popAttributes() {
        self.attributes = self.attributeStack.removeLast()
    }

    private mutating func append(_ string: String) {
        guard !string.isEmpty else {
            return
        }

        self.result.append(AttributedText(string, attributes: self.attributes))
    }
}
