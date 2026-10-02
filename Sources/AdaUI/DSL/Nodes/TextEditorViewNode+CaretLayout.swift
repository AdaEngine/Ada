import AdaText

extension TextEditorViewNode {
    struct CaretLayoutCacheKey: Hashable {
        let text: String
        let font: Font
        let lineHeight: Float
    }

    final class CachedCaretLayout {
        let stops: [Float]
        let characterCount: Int
        var lastAccess: UInt64

        init(stops: [Float], characterCount: Int, lastAccess: UInt64) {
            self.stops = stops
            self.characterCount = characterCount
            self.lastAccess = lastAccess
        }

        func xOffset(forColumn column: Int) -> Float {
            // Preserve Character-based editing, including combined emoji and leading whitespace.
            let clamped = max(0, min(column, characterCount))
            return stops[min(clamped, stops.count - 1)]
        }
    }

    /// Geometry depends on text and font metrics, so color/hover changes can reuse these positions.
    func cachedCaretLayout(for lineText: String, font: Font?, pointSize: Float) -> CachedCaretLayout? {
        guard let font else {
            return nil
        }
        let height = self.lineHeight(for: pointSize)
        let key = CaretLayoutCacheKey(text: lineText, font: font, lineHeight: height)
        self.caretLayoutCacheAccess &+= 1
        if let cached = self.caretLayoutCache[key] {
            cached.lastAccess = self.caretLayoutCacheAccess
            self.caretLayoutCacheHits += 1
            return cached
        }

        var stops: [Float] = [0]
        let characterCount = lineText.count
        if !lineText.isEmpty {
            var attributes = TextAttributeContainer()
            attributes.font = font
            let layout = self.makeTextLayout(for: AttributedText(lineText, attributes: attributes), lineHeight: height)
            stops.reserveCapacity(characterCount + 1)
            for line in layout.textLines {
                for run in line {
                    for glyph in run {
                        stops.append(max(stops.last ?? 0, glyph.advanceX))
                    }
                }
            }
        }

        let cached = CachedCaretLayout(stops: stops, characterCount: characterCount, lastAccess: self.caretLayoutCacheAccess)
        self.caretLayoutCacheMisses += 1
        self.caretLayoutCache[key] = cached
        self.pruneCaretLayoutCacheIfNeeded()
        return cached
    }

    private func pruneCaretLayoutCacheIfNeeded() {
        guard self.caretLayoutCache.count > 384 else {
            return
        }
        let staleKeys = self.caretLayoutCache
            .sorted { $0.value.lastAccess < $1.value.lastAccess }
            .prefix(self.caretLayoutCache.count - 320)
            .map(\.key)
        for key in staleKeys {
            self.caretLayoutCache.removeValue(forKey: key)
        }
    }
}
