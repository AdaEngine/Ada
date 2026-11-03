@_spi(AdaEngine) import AdaEngine
import Math

/// Per-mounted-message parsing cache. Parent reconciliation does not reparse history.
@MainActor
final class EditorAgentMarkdownCache {
    private var source: String?
    private var blocks: [TextMarkdownBlock] = []

    func document(_ text: String) -> [TextMarkdownBlock] {
        guard source != text else { return blocks }
        blocks = TextMarkdownBlock.parse(text, reusing: blocks)
        source = text
        return blocks
    }
}

struct EditorAgentMarkdown: View {
    let source: String
    var fontSize: Double = 14
    @State private var cache = EditorAgentMarkdownCache()

    var body: some View {
        EditorAgentMarkdownBlocks(blocks: cache.document(source), fontSize: fontSize)
    }
}

private struct EditorAgentMarkdownBlocks: View {
    let blocks: [TextMarkdownBlock]
    let fontSize: Double
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block.content)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ content: TextMarkdownBlock.Content) -> some View {
        switch content {
        case let .text(text):
            styledText(text)
        case let .code(code, language):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(verbatim: language)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.editorColors.muted)
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(verbatim: code.hasSuffix("\n") ? String(code.dropLast()) : code)
                        .font(Font.system(size: fontSize - 1).applyingTraits(.code))
                        .foregroundColor(theme.editorColors.text)
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.background))
            .accessibilityIdentifier("AdaEditor.Agent.Markdown.Code")
        case let .quote(children):
            HStack(alignment: .top, spacing: 10) {
                RectangleShape().fill(theme.editorColors.blue.opacity(0.5)).frame(width: 3)
                AnyView(EditorAgentMarkdownBlocks(blocks: children, fontSize: fontSize))
            }
            .accessibilityIdentifier("AdaEditor.Agent.Markdown.Quote")
        case let .table(header, rows):
            ScrollView(.horizontal, showsIndicators: true) {
                EditorAgentMarkdownTableLayout(columns: max(1, header.count)) {
                    ForEach(Array(([header] + rows).enumerated()), id: \.offset) { rowIndex, row in
                        ForEach(Array(header.indices), id: \.self) { column in
                            styledText(column < row.count ? row[column] : AttributedText(""))
                                .padding(8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .background(rowIndex == 0 ? theme.editorColors.surface : .clear)
                                .overlay { RectangleShape().stroke(theme.editorColors.border, lineWidth: 1) }
                        }
                    }
                }
            }
            .accessibilityIdentifier("AdaEditor.Agent.Markdown.Table")
        case .divider:
            RectangleShape().fill(theme.editorColors.border).frame(height: 1)
        }
    }

    private func styledText(_ text: AttributedText) -> some View {
        Text(text)
            .font(.system(size: fontSize))
            .foregroundColor(theme.editorColors.text)
            .textSelection(.enabled)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Share each measured row height across columns, including wrapped multi-line cells.
private struct EditorAgentMarkdownTableLayout: Layout {
    let columns: Int
    private let columnWidth: Float = 180

    func sizeThatFits(_ proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) -> Size {
        Size(width: columnWidth * Float(columns), height: rowHeights(subviews).reduce(0, +))
    }

    func placeSubviews(in bounds: Rect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout Void) {
        let heights = rowHeights(subviews)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                var cellProposal = ProposedViewSize.unspecified
                cellProposal.width = columnWidth
                cellProposal.height = height
                subviews[index].place(
                    at: Point(bounds.minX + Float(column) * columnWidth, y),
                    anchor: .topLeading,
                    proposal: cellProposal
                )
            }
            y += height
        }
    }

    private func rowHeights(_ subviews: Subviews) -> [Float] {
        var heights: [Float] = []
        for (index, view) in subviews.enumerated() {
            if index % columns == 0 { heights.append(0) }
            var proposal = ProposedViewSize.unspecified
            proposal.width = columnWidth
            heights[index / columns] = max(heights[index / columns], view.sizeThatFits(proposal).height)
        }
        return heights
    }
}
