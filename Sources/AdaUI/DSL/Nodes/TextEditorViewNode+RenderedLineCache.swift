import AdaText
import AdaUtils

extension TextEditorViewNode {
    struct RenderedLineCacheKey: Equatable {
        let text: String
        let spans: [TextEditorTokenSpan]
        let font: Font
        let color: Color
        let hoveredRange: TextEditorSourceRange?
        let hoverColor: Color?
    }

    final class CachedRenderedLine {
        let key: RenderedLineCacheKey
        let layout: TextLayoutManager
        let verticalOffset: Float
        var lastAccess: UInt64

        init(key: RenderedLineCacheKey, layout: TextLayoutManager, verticalOffset: Float, lastAccess: UInt64) {
            self.key = key
            self.layout = layout
            self.verticalOffset = verticalOffset
            self.lastAccess = lastAccess
        }
    }

    /// Reuse styled glyphs without constructing or comparing per-character attribute dictionaries on a hit.
    func cachedRenderedLine(key: RenderedLineCacheKey, lineIndex: Int) -> CachedRenderedLine {
        self.renderedLineCacheAccess &+= 1
        if let cached = self.renderedLineCache[lineIndex], cached.key == key {
            cached.lastAccess = self.renderedLineCacheAccess
            self.renderedLineCacheHits += 1
            return cached
        }
        let attributedText = self.attributedLineText(
            key.text,
            lineSpans: key.spans,
            font: key.font,
            fallbackColor: key.color,
            hoveredRange: key.hoveredRange,
            lineIndex: lineIndex,
            hoverColor: key.hoverColor
        )
        let height = self.lineHeight(for: Float(key.font.pointSize))
        let layout = self.makeTextLayout(for: attributedText, lineHeight: height)
        let cached = CachedRenderedLine(
            key: key,
            layout: layout,
            verticalOffset: Self.verticalTextOffset(for: layout, height: height),
            lastAccess: self.renderedLineCacheAccess
        )
        self.renderedLineCache[lineIndex] = cached
        self.renderedLineCacheMisses += 1
        if self.renderedLineCache.count > 384 {
            let staleLines = self.renderedLineCache
                .sorted { $0.value.lastAccess < $1.value.lastAccess }
                .prefix(self.renderedLineCache.count - 320)
                .map(\.key)
            for line in staleLines {
                self.renderedLineCache.removeValue(forKey: line)
            }
        }
        return cached
    }
}
