//
//  TextLayoutManager.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/6/23.
//

import AdaRender
import AdaUtils
import AtlasFontGenerator
import Foundation
import Math

// FIXME: Fix TextRun, that should equals AttributedString.Run
/// A region where text layout occurs.
public struct TextContainer: Hashable {
    /// The text for rendering.
    public var text: AttributedText

    /// The alignment of text in the box.
    /// - Warning: Under development.
    public var textAlignment: TextAlignment

    /// The wrapping behavior inside the text container.
    /// - Warning: Under development.
    public var lineBreakMode: LineBreakMode

    /// The spacing between lines.
    public var lineSpacing: Float

    /// The maximum number of lines for rendering text.
    public var numberOfLines: Int?

    /// Whether typographic shaping can substitute multiple characters with a
    /// single glyph. Editable text should keep this disabled until caret and
    /// selection logic is cluster-aware.
    public var allowsShaping: Bool

    /// The base direction used to resolve leading alignment and bidirectional runs.
    public var writingDirection: TextWritingDirection

    public init(
        text: AttributedText,
        textAlignment: TextAlignment,
        lineBreakMode: LineBreakMode,
        lineSpacing: Float,
        allowsShaping: Bool = true,
        writingDirection: TextWritingDirection = .natural
    ) {
        self.text = text
        self.textAlignment = textAlignment
        self.lineBreakMode = lineBreakMode
        self.lineSpacing = lineSpacing
        self.allowsShaping = allowsShaping
        self.writingDirection = writingDirection
    }

    public init(
        text: AttributedText,
        textAlignment: TextAlignment = .center,
        lineBreakMode: LineBreakMode = .byCharWrapping,
        lineSpacing: Float = 0,
        writingDirection: TextWritingDirection = .natural
    ) {
        self.init(
            text: text,
            textAlignment: textAlignment,
            lineBreakMode: lineBreakMode,
            lineSpacing: lineSpacing,
            allowsShaping: true,
            writingDirection: writingDirection
        )
    }

    public init() {
        self.text = ""
        self.textAlignment = .center
        self.lineBreakMode = .byCharWrapping
        self.lineSpacing = 0
        self.allowsShaping = true
        self.writingDirection = .natural
    }
}

struct TextLineBreakRules {
    static func isJapaneseWrappingContext(
        at index: String.Index,
        in string: String,
        rowStartIndex: String.Index
    ) -> Bool {
        guard index < string.endIndex else {
            return false
        }

        if isJapaneseLike(string[index]) {
            return true
        }

        guard index > rowStartIndex else {
            return false
        }

        let previousIndex = string.index(before: index)
        return isJapaneseLike(string[previousIndex])
    }

    static func canBreakJapaneseLine(
        before index: String.Index,
        in string: String,
        rowStartIndex: String.Index
    ) -> Bool {
        guard index > rowStartIndex && index < string.endIndex else {
            return false
        }

        let current = string[index]
        let previous = string[string.index(before: index)]

        if isProhibitedLineStart(current) {
            return false
        }

        if isProhibitedLineEnd(previous) {
            return false
        }

        return true
    }

    private static func isJapaneseLike(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            isJapaneseScalar(scalar) || isJapanesePunctuationScalar(scalar)
        }
    }

    private static func isJapaneseScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x309F,  // Hiragana
            0x30A0...0x30FF,  // Katakana
            0x31F0...0x31FF,  // Katakana Phonetic Extensions
            0x3400...0x4DBF,  // CJK Unified Ideographs Extension A
            0x4E00...0x9FFF,  // CJK Unified Ideographs
            0xF900...0xFAFF:  // CJK Compatibility Ideographs
            return true
        default:
            return false
        }
    }

    private static func isJapanesePunctuationScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,
            0xFE30...0xFE4F:
            return true
        default:
            return false
        }
    }

    private static func isProhibitedLineStart(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3001,  // 、
                0x3002,  // 。
                0x3009,  // 〉
                0x300B,  // 》
                0x300D,  // 」
                0x300F,  // 』
                0x3011,  // 】
                0x3015,  // 〕
                0x3017,  // 〗
                0x3019,  // 〙
                0x301B,  // 〛
                0x30FB,  // ・
                0x30FC,  // ー
                0xFF09,  // ）
                0xFF0C,  // ，
                0xFF0E,  // ．
                0xFF1A,  // ：
                0xFF1B,  // ；
                0xFF1F,  // ？
                0xFF3D,  // ］
                0xFF5D,  // ｝
                0xFF60,  // ｣
                0xFF61:  // ｡
                return true
            case 0x3041,
                0x3043,
                0x3045,
                0x3047,
                0x3049,
                0x3063,
                0x3083,
                0x3085,
                0x3087,
                0x308E,
                0x3095,
                0x3096,
                0x30A1,
                0x30A3,
                0x30A5,
                0x30A7,
                0x30A9,
                0x30C3,
                0x30E3,
                0x30E5,
                0x30E7,
                0x30EE,
                0x30F5,
                0x30F6:
                return true
            case 0x3008,  // 〈
                0x300A,  // 《
                0x300C,  // 「
                0x300E,  // 『
                0x3010,  // 【
                0x3014,  // 〔
                0x3016,  // 〖
                0x3018,  // 〘
                0x301A,  // 〚
                0xFF08,  // （
                0xFF3B,  // ［
                0xFF5B,  // ｛
                0xFF5F:  // ｟
                return true
            default:
                return false
            }
        }
    }

    private static func isProhibitedLineEnd(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3008,  // 〈
                0x300A,  // 《
                0x300C,  // 「
                0x300E,  // 『
                0x3010,  // 【
                0x3014,  // 〔
                0x3016,  // 〖
                0x3018,  // 〘
                0x301A,  // 〚
                0xFF08,  // （
                0xFF3B,  // ［
                0xFF5B,  // ｛
                0xFF5F:  // ｟
                return true
            default:
                return false
            }
        }
    }
}

/// An object that coordinates the layout and display of text characters.
/// TextLayoutManager maps unicods characters codes to glyphs.
public final class TextLayoutManager: @unchecked Sendable {
    enum Constants {
        static let questionMark = Character("?").unicodeScalars.first.unwrap(message: "Question mark has no Unicode scalar.")
        static let dots = Character("…").unicodeScalars.first.unwrap(message: "Ellipsis has no Unicode scalar.")
        static let maxTexturesPerBatch = 16
    }

    private var textContainer: TextContainer = TextContainer(
        text: "",
        textAlignment: .center,
        lineBreakMode: .byCharWrapping,
        lineSpacing: 0
    )

    /// The typographic size before alignment, bounded by the available size.
    /// This includes glyph advances but excludes distance-field atlas padding
    /// and the unused width of a finite text container.
    public private(set) var size: Size = .zero
    public private(set) var textLines: [TextLine] = []

    /// The text alignment of the text container.
    public var textAlignment: TextAlignment {
        textContainer.textAlignment
    }

    /// The physical alignment after resolving leading and trailing against the writing direction.
    public var resolvedTextAlignment: TextAlignment {
        guard textContainer.writingDirection.resolved(for: textContainer.text.text) == .rightToLeft else {
            return textContainer.textAlignment
        }

        return switch textContainer.textAlignment {
        case .leading: .trailing
        case .trailing: .leading
        case .center: .center
        }
    }

    /// All glyphs for render in text contaner bounds
    private var glyphs: [Glyph] = []
    private var glyphsToRender: GlyphRenderData?

    private var availableSize: Size = Size(width: .infinity, height: .infinity)
    private var isLayoutValid = false

    /// Monotonically increasing revision of the computed text layout.
    ///
    /// This is intentionally internal so tests and engine diagnostics can verify
    /// that stable constraints reuse the existing glyph layout.
    private(set) var layoutRevision: UInt64 = 0

    public init() {}

    private struct ResolvedGlyph {
        let glyph: FontHandle.Glyph
        let fontResource: FontResource
        let scalar: UnicodeScalar
    }

    private func resolveGlyph(for scalar: UnicodeScalar, primaryFontResource: FontResource) -> ResolvedGlyph? {
        if let glyph = primaryFontResource.handle.getGlyph(for: scalar.value) {
            return ResolvedGlyph(glyph: glyph, fontResource: primaryFontResource, scalar: scalar)
        }

        if let fallbackFontResource = FontResource.fallback(for: scalar, baseFont: primaryFontResource),
            let glyph = fallbackFontResource.handle.getGlyph(for: scalar.value) {
            return ResolvedGlyph(glyph: glyph, fontResource: fallbackFontResource, scalar: scalar)
        }

        guard let glyph = primaryFontResource.handle.getGlyph(for: Constants.questionMark.value) else {
            return nil
        }

        return ResolvedGlyph(glyph: glyph, fontResource: primaryFontResource, scalar: Constants.questionMark)
    }

    private func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
    }

    private func nextNonWhitespaceIndex(
        from startIndex: String.Index,
        in string: String,
        limitedBy endIndex: String.Index
    ) -> String.Index {
        var index = startIndex
        while index < endIndex && isWhitespace(string[index]) {
            index = string.index(after: index)
        }
        return index
    }

    private func nextWordEndIndex(
        from startIndex: String.Index,
        in string: String,
        limitedBy endIndex: String.Index
    ) -> String.Index {
        var index = startIndex
        while index < endIndex && !isWhitespace(string[index]) {
            index = string.index(after: index)
        }
        return index
    }

    private func isWordStart(
        at index: String.Index,
        in string: String,
        lineStartIndex: String.Index
    ) -> Bool {
        if isWhitespace(string[index]) {
            return false
        }

        if index == lineStartIndex {
            return true
        }

        let previousIndex = string.index(before: index)
        return isWhitespace(string[previousIndex])
    }

    private func typographicWidth(
        of range: Range<String.Index>,
        in attributedText: AttributedText
    ) -> Float {
        var x: Double = 0
        var index = range.lowerBound

        while index < range.upperBound {
            let attributes = attributedText.attributes(at: index)
            let char = attributedText.text[index]
            let kern = Double(attributes.kern)
            let font = attributes.font
            let primaryFontResource = font.fontResource

            guard let firstScalar = char.unicodeScalars.first else {
                index = attributedText.text.index(after: index)
                continue
            }

            if let resolvedGlyph = resolveGlyph(for: firstScalar, primaryFontResource: primaryFontResource) {
                let glyph = resolvedGlyph.glyph
                let glyphFontResource = resolvedGlyph.fontResource
                let glyphFontHandle = glyphFontResource.handle
                let glyphMetrics = glyphFontHandle.metrics
                let glyphFontScale = font.pointSize / glyphMetrics.emSize

                var advance = glyph.advance
                let nextIndex = attributedText.text.index(after: index)
                if nextIndex < range.upperBound,
                    let nextScalar = attributedText.text[nextIndex].unicodeScalars.first {
                    glyphFontHandle.getAdvance(&advance, resolvedGlyph.scalar.value, nextScalar.value)
                }
                x += glyphFontScale * advance + kern
            } else {
                let nextIndex = attributedText.text.index(after: index)
                if nextIndex < range.upperBound {
                    x += kern
                }
            }

            index = attributedText.text.index(after: index)
        }

        return Float(x)
    }

    private func shiftedGlyph(_ glyph: Glyph, offsetByX offset: Float) -> Glyph {
        Glyph(
            textureAtlas: glyph.textureAtlas,
            textureCoordinates: glyph.textureCoordinates,
            attributes: glyph.attributes,
            position: [
                glyph.position.x + offset,
                glyph.position.y,
                glyph.position.z + offset,
                glyph.position.w,
            ],
            advanceX: glyph.advanceX + offset,
            origin: glyph.origin,
            size: glyph.size
        )
    }

    /// Set new text container to text layout.
    /// - Note: This method doesn't call ``invalidateLayout()`` method.
    public func setTextContainer(_ textContainer: TextContainer) {
        if self.textContainer != textContainer {
            self.textContainer = textContainer
            self.glyphsToRender = nil
            self.isLayoutValid = false
        }
    }

    /// Set new constraints for size rendering.
    public func fitToSize(_ size: Size) {
        guard self.availableSize != size || !isLayoutValid else {
            return
        }

        self.availableSize = size
        self.glyphsToRender = nil
        self.invalidateLayout()
    }

    private var hasAvailableSpace: Bool {
        availableSize.width > 0 && availableSize.height > 0 && textContainer.numberOfLines != 0
    }

    private func canStartLine(at baseline: Double, height: Double, rowCount: Int) -> Bool {
        rowCount < (textContainer.numberOfLines ?? Int.max)
            && (rowCount == 0 || Float(-baseline + height) <= availableSize.height)
    }

    // swiftlint:disable function_body_length

    // FIXME: TextLayoutManager calculate the wrong position
    /// Invalidate text layout, update text lines and glyphs.
    public func invalidateLayout() {
        self.isLayoutValid = false
        self.layoutRevision &+= 1
        var x: Double = 0
        var y: Double = 0

        self.glyphsToRender = nil
        let lineHeightOffset = Double(self.textContainer.lineSpacing)
        let attributedText = self.textContainer.text

        let lines = attributedText.text.components(separatedBy: .newlines)
        self.textLines = []
        self.size = .zero

        let numberOfLines = self.textContainer.numberOfLines ?? Int.max
        if numberOfLines < 0 {
            assertionFailure("Line limit can't be less than zero.")
            return
        }

        guard hasAvailableSpace else {
            self.isLayoutValid = true
            return
        }

        var currentTextIndex = attributedText.text.startIndex
        var visualRowCount = 0
        var reachedLimit = false

        for lineString in lines[..<min(numberOfLines, lines.count)] {
            guard !reachedLimit else {
                break
            }
            // Find the range of this line in the original attributed text
            let lineStartIndex = currentTextIndex
            let lineEndIndex = attributedText.text.index(lineStartIndex, offsetBy: lineString.count, limitedBy: attributedText.text.endIndex) ?? attributedText.text.endIndex

            // Handle newline character if not at the end
            if lineEndIndex < attributedText.text.endIndex && attributedText.text[lineEndIndex] == "\n" {
                currentTextIndex = attributedText.text.index(after: lineEndIndex)
            } else {
                currentTextIndex = lineEndIndex
            }

            let lineRange = lineStartIndex..<lineEndIndex
            let initialFont = attributedText.attributes(at: lineStartIndex).font
            let initialLineHeight = initialFont.lineHeight + lineHeightOffset
            guard canStartLine(at: y, height: initialLineHeight, rowCount: visualRowCount) else {
                break
            }
            visualRowCount += 1
            var textLine = TextLine(attributedText: attributedText, range: lineRange)
            var textRun = TextRun()

            // Reset x for each new line, but keep accumulating y
            x = 0

            // Calculate the starting y position for this line's bounding box
            let lineStartY = y

            var maxWidth: Double = 0
            var maxAscent: Double = 0
            var maxDescent: Double = 0
            var maxLineHeight: Double = initialLineHeight
            var visualRowStartGlyphIndex = 0
            var visualRowStartTextIndex = lineStartIndex

            func alignCurrentVisualRow() {
                guard visualRowStartGlyphIndex < textRun.glyphs.count else {
                    visualRowStartGlyphIndex = textRun.glyphs.count
                    return
                }

                // Atlas quads include distance-field padding and must not
                // influence measurement, alignment, or line breaking.
                let rowWidth = Float(x)
                self.size.width = max(self.size.width, rowWidth)
                var offset: Float = 0

                if self.availableSize.width.isFinite && self.availableSize.width > rowWidth {
                    switch self.resolvedTextAlignment {
                    case .leading:
                        offset = 0
                    case .center:
                        offset = (self.availableSize.width - rowWidth) / 2
                    case .trailing:
                        offset = self.availableSize.width - rowWidth
                    }
                }

                if offset != 0 {
                    for glyphIndex in visualRowStartGlyphIndex..<textRun.glyphs.count {
                        textRun.glyphs[glyphIndex] = shiftedGlyph(textRun.glyphs[glyphIndex], offsetByX: offset)
                    }
                }

                maxWidth = max(maxWidth, Double(offset) + Double(rowWidth))
                visualRowStartGlyphIndex = textRun.glyphs.count
            }

            func startVisualRow(at textIndex: String.Index) -> Bool {
                guard
                    visualRowCount < numberOfLines,
                    Float(-y + 2 * maxLineHeight) <= availableSize.height
                else {
                    reachedLimit = true
                    return false
                }
                alignCurrentVisualRow()
                x = 0
                y -= maxLineHeight
                visualRowStartTextIndex = textIndex
                visualRowCount += 1
                return true
            }

            func matchingAttributeRunEnd(
                from startIndex: String.Index,
                attributes: TextAttributeContainer
            ) -> String.Index {
                var runEndIndex = startIndex
                while runEndIndex < lineEndIndex && attributedText.attributes(at: runEndIndex) == attributes {
                    runEndIndex = attributedText.text.index(after: runEndIndex)
                }
                return runEndIndex
            }

            func appendGlyphToCurrentRun(
                glyph: FontHandle.Glyph,
                fontResource: FontResource,
                attributes: TextAttributeContainer,
                baselineX: Double,
                baselineY: Double,
                pointSize: Double,
                xOffset: Double = 0,
                yOffset: Double = 0,
                advanceX: Double
            ) {
                let glyphFontHandle = fontResource.handle
                let glyphMetrics = glyphFontHandle.metrics
                let glyphFontScale = pointSize / glyphMetrics.emSize
                let glyphFontSize = fontResource.getFontScale(for: pointSize)

                var l: Double = 0
                var b: Double = 0
                var r: Double = 0
                var t: Double = 0
                glyph.getQuadAtlasBounds(&l, &b, &r, &t)

                var pl: Double = 0
                var pb: Double = 0
                var pr: Double = 0
                var pt: Double = 0
                glyph.getQuadPlaneBounds(&pl, &pb, &pr, &pt)

                pl = (pl + xOffset) * glyphFontScale + baselineX
                pb = (pb + yOffset) * glyphFontScale + baselineY
                pr = (pr + xOffset) * glyphFontScale + baselineX
                pt = (pt + yOffset) * glyphFontScale + baselineY

                let texelWidth = 1 / Double(glyphFontHandle.atlasTexture.width)
                let texelHeight = 1 / Double(glyphFontHandle.atlasTexture.height)
                l *= texelWidth
                b *= texelHeight
                r *= texelWidth
                t *= texelHeight

                textRun.glyphs.append(
                    Glyph(
                        textureAtlas: glyphFontHandle.atlasTexture,
                        textureCoordinates: [Float(l), Float(b), Float(r), Float(t)],
                        attributes: attributes,
                        position: [Float(pl), Float(pb), Float(pr), Float(pt)],
                        advanceX: Float(advanceX),
                        origin: Point(x: -Float(glyphFontSize) / 2, y: Float(glyphFontSize) / 2),
                        size: Size(width: Float(glyphFontSize), height: Float(glyphFontSize))
                    )
                )
            }

            func appendShapedRunIfPossible(
                from startIndex: String.Index,
                attributes: TextAttributeContainer,
                font: Font,
                fontResource: FontResource
            ) -> String.Index? {
                guard self.textContainer.allowsShaping else {
                    return nil
                }

                let runEndIndex = matchingAttributeRunEnd(from: startIndex, attributes: attributes)
                guard startIndex < runEndIndex else {
                    return nil
                }

                let runText = String(attributedText.text[startIndex..<runEndIndex])
                let shapedGlyphs = TextShaper.shape(
                    runText,
                    font: fontResource,
                    writingDirection: textContainer.writingDirection
                )
                guard !shapedGlyphs.isEmpty else {
                    return nil
                }

                var renderGlyphs: [(shaped: ShapedGlyph, glyph: FontHandle.Glyph, isWhitespace: Bool)] = []
                renderGlyphs.reserveCapacity(shapedGlyphs.count)
                for shapedGlyph in shapedGlyphs {
                    guard let glyph = fontResource.handle.getGlyph(forGlyphIndex: shapedGlyph.glyphIndex) else {
                        return nil
                    }

                    let utf8Offset = min(max(shapedGlyph.cluster, 0), runText.utf8.count)
                    let utf8Index = runText.utf8.index(runText.utf8.startIndex, offsetBy: utf8Offset)
                    let stringIndex = String.Index(utf8Index, within: runText) ?? runText.startIndex
                    let whitespace = stringIndex < runText.endIndex && isWhitespace(runText[stringIndex])
                    renderGlyphs.append((shapedGlyph, glyph, whitespace))
                }

                let glyphFontScale = font.pointSize / fontResource.handle.metrics.emSize
                let kern = Double(attributes.kern)

                func advance(from lowerBound: Int, to upperBound: Int) -> Double {
                    renderGlyphs[lowerBound..<upperBound]
                        .reduce(0) { partialResult, item in
                            partialResult + (item.shaped.xAdvance * glyphFontScale) + kern
                        }
                }

                var renderIndex = 0
                while renderIndex < renderGlyphs.count {
                    let groupIsWhitespace = renderGlyphs[renderIndex].isWhitespace
                    var groupEndIndex = renderIndex + 1
                    while groupEndIndex < renderGlyphs.count
                        && renderGlyphs[groupEndIndex].isWhitespace == groupIsWhitespace {
                        groupEndIndex += 1
                    }

                    if textContainer.lineBreakMode == .byWordWrapping && availableSize.width.isFinite && x > 0 {
                        let groupAdvance = advance(from: renderIndex, to: groupEndIndex)
                        var widthBeforeNextWord = groupAdvance
                        if groupIsWhitespace && groupEndIndex < renderGlyphs.count {
                            var nextWordEndIndex = groupEndIndex + 1
                            while nextWordEndIndex < renderGlyphs.count && !renderGlyphs[nextWordEndIndex].isWhitespace {
                                nextWordEndIndex += 1
                            }
                            widthBeforeNextWord += advance(from: groupEndIndex, to: nextWordEndIndex)
                        }

                        if Float(x + widthBeforeNextWord) > availableSize.width {
                            guard startVisualRow(at: startIndex) else {
                                return lineEndIndex
                            }
                            if groupIsWhitespace {
                                renderIndex = groupEndIndex
                                continue
                            }
                        }
                    }

                    while renderIndex < groupEndIndex {
                        let (shapedGlyph, glyph, _) = renderGlyphs[renderIndex]
                        let projectedAdvance = Float(x + shapedGlyph.xAdvance * glyphFontScale + kern)
                        if projectedAdvance > availableSize.width && x > 0 {
                            guard startVisualRow(at: startIndex) else {
                                return lineEndIndex
                            }
                        }

                        appendGlyphToCurrentRun(
                            glyph: glyph,
                            fontResource: fontResource,
                            attributes: attributes,
                            baselineX: x,
                            baselineY: y,
                            pointSize: font.pointSize,
                            xOffset: shapedGlyph.xOffset,
                            yOffset: shapedGlyph.yOffset,
                            advanceX: x + (shapedGlyph.xAdvance * glyphFontScale) + kern
                        )

                        x += (shapedGlyph.xAdvance * glyphFontScale) + kern
                        renderIndex += 1
                    }
                }

                return runEndIndex
            }

            func wrapBeforeWord(at index: inout String.Index) {
                guard
                    textContainer.lineBreakMode == .byWordWrapping,
                    availableSize.width.isFinite, x > 0
                else {
                    return
                }
                let wordStartIndex: String.Index
                if isWhitespace(attributedText.text[index]) {
                    wordStartIndex = nextNonWhitespaceIndex(
                        from: index,
                        in: attributedText.text,
                        limitedBy: lineEndIndex
                    )
                } else if isWordStart(at: index, in: attributedText.text, lineStartIndex: lineStartIndex) {
                    wordStartIndex = index
                } else {
                    return
                }
                guard wordStartIndex < lineEndIndex else {
                    return
                }
                let wordEndIndex = nextWordEndIndex(
                    from: wordStartIndex,
                    in: attributedText.text,
                    limitedBy: lineEndIndex
                )
                let width = typographicWidth(of: index..<wordEndIndex, in: attributedText)
                if Float(x) + width > availableSize.width, startVisualRow(at: wordStartIndex) {
                    index = wordStartIndex
                }
            }

            var index = lineStartIndex
            while index < lineEndIndex {
                wrapBeforeWord(at: &index)
                if reachedLimit {
                    break
                }

                let attributes = attributedText.attributes(at: index)
                let char = attributedText.text[index]

                let kern = Double(attributes.kern)

                let font = attributes.font
                let primaryFontResource = font.fontResource
                let fontHandle = primaryFontResource.handle
                let metrics = fontHandle.metrics
                // Scale glyph positions based on font point size relative to em size
                let fontScale: Double = font.pointSize / metrics.emSize
                let lineHeight = fontScale * metrics.lineHeight
                maxLineHeight = max(maxLineHeight, lineHeight + lineHeightOffset)
                maxAscent = max(maxAscent, metrics.ascenderY * fontScale)
                maxDescent = max(maxDescent, abs(metrics.descenderY * fontScale))

                if let nextIndex = appendShapedRunIfPossible(
                    from: index,
                    attributes: attributes,
                    font: font,
                    fontResource: primaryFontResource
                ) {
                    index = nextIndex
                    continue
                }

                guard let firstScalar = char.unicodeScalars.first else {
                    if index < lineEndIndex {
                        index = attributedText.text.index(after: index)
                    }
                    continue
                }

                if let resolvedGlyph = resolveGlyph(for: firstScalar, primaryFontResource: primaryFontResource) {
                    let glyph = resolvedGlyph.glyph
                    let glyphFontResource = resolvedGlyph.fontResource
                    let glyphFontHandle = glyphFontResource.handle
                    let glyphMetrics = glyphFontHandle.metrics
                    let glyphFontScale: Double = font.pointSize / glyphMetrics.emSize
                    let glyphFontSize = glyphFontResource.getFontScale(for: font.pointSize)

                    var advance = glyph.advance
                    let nextIndex = attributedText.text.index(after: index)
                    if nextIndex < lineEndIndex,
                        let nextScalar = attributedText.text[nextIndex].unicodeScalars.first {
                        glyphFontHandle.getAdvance(&advance, resolvedGlyph.scalar.value, nextScalar.value)
                    }

                    var l: Double = 0
                    var b: Double = 0
                    var r: Double = 0
                    var t: Double = 0
                    glyph.getQuadAtlasBounds(&l, &b, &r, &t)

                    var pl: Double = 0
                    var pb: Double = 0
                    var pr: Double = 0
                    var pt: Double = 0
                    glyph.getQuadPlaneBounds(&pl, &pb, &pr, &pt)

                    let shouldWrapBeforeGlyph = Float(x + glyphFontScale * advance + kern) > availableSize.width
                    let isJapaneseWrappingContext = TextLineBreakRules.isJapaneseWrappingContext(
                        at: index,
                        in: attributedText.text,
                        rowStartIndex: visualRowStartTextIndex
                    )
                    let canWrapBeforeGlyph =
                        self.textContainer.lineBreakMode != .byWordWrapping
                        || !isJapaneseWrappingContext
                        || TextLineBreakRules.canBreakJapaneseLine(
                            before: index,
                            in: attributedText.text,
                            rowStartIndex: visualRowStartTextIndex
                        )

                    if shouldWrapBeforeGlyph && canWrapBeforeGlyph && x > 0 {
                        guard startVisualRow(at: index) else {
                            break
                        }
                    }

                    let nextCaretX = x + glyphFontScale * advance + kern

                    pl = (pl * glyphFontScale) + x
                    pb = (pb * glyphFontScale) + y
                    pr = (pr * glyphFontScale) + x
                    pt = (pt * glyphFontScale) + y

                    let texelWidth = 1 / Double(glyphFontHandle.atlasTexture.width)
                    let texelHeight = 1 / Double(glyphFontHandle.atlasTexture.height)
                    l *= texelWidth
                    b *= texelHeight
                    r *= texelWidth
                    t *= texelHeight

                    textRun.glyphs.append(
                        Glyph(
                            textureAtlas: glyphFontHandle.atlasTexture,
                            textureCoordinates: [Float(l), Float(b), Float(r), Float(t)],
                            attributes: attributes,
                            position: [Float(pl), Float(pb), Float(pr), Float(pt)],
                            advanceX: Float(nextCaretX),
                            origin: Point(x: -Float(glyphFontSize) / 2, y: Float(glyphFontSize) / 2),
                            size: Size(width: Float(glyphFontSize), height: Float(glyphFontSize))
                        )
                    )

                    x = nextCaretX
                }

                if index < lineEndIndex {
                    index = attributedText.text.index(after: index)
                } else {
                    break
                }
            }

            alignCurrentVisualRow()

            textLine.runs.append(textRun)

            // Soft-wrapped visual rows share the same source line, so include
            // every row in the measured height instead of only the first row.
            let visualHeight = maxLineHeight > 0 ? (lineStartY - y) + maxLineHeight : 0
            let boundingWidth =
                self.availableSize.width.isFinite && !textRun.glyphs.isEmpty
                ? Double(self.availableSize.width)
                : maxWidth

            // Calculate bounding box for this line
            let boundingBox = Rect(
                origin: Point(x: 0, y: Float(lineStartY)),
                size: Size(width: Float(boundingWidth), height: Float(visualHeight))
            )

            textLine.typographicBounds.ascent = maxAscent
            textLine.typographicBounds.descent = maxDescent
            textLine.typographicBounds.rect = boundingBox
            self.textLines.append(textLine)

            self.size.height += Float(visualHeight)

            // Move y down for the next line
            y -= maxLineHeight
        }
        self.size.width = min(self.size.width, availableSize.width)
        self.size.height = min(self.size.height, availableSize.height)
        self.isLayoutValid = true
    }

    /// Get or create glyphs vertex data relative to transform.
    public func getGlyphVertexData(
        transform: Transform3D,
        ignoreCache: Bool = false
    ) -> GlyphRenderData {
        var textures: [Texture2D] = .init(repeating: .whiteTexture, count: 16)
        if let glyphsToRender, glyphsToRender.transform == transform, !ignoreCache {
            return glyphsToRender
        }

        // Use actual visible glyph extents for alignment so short labels stay
        // optically centered even when typographic width includes side bearings.
        var offsetY: Float = 0

        let textSize = self.boundingSize()
        if let firstLine = textLines.first, !textLines.isEmpty {
            let topY = firstLine.typographicBounds.rect.origin.y
            let bottomY = topY - textSize.height
            offsetY = -(topY + bottomY) / 2
        }

        var verticies: [GlyphVertexData] = []
        var indeciesCount: Int = 0

        var textureIndex: Int = -1

        for textLine in textLines {
            let lineBounds = self.visualBounds(for: textLine)
            let lineOffsetX: Float =
                switch self.resolvedTextAlignment {
                case .center:
                    -((lineBounds.minX + lineBounds.maxX) / 2)
                case .leading:
                    -lineBounds.minX
                case .trailing:
                    -lineBounds.maxX
                }

            for run in textLine {
                for glyph in run {
                    let texture = glyph.textureAtlas
                    let foregroundColor = glyph.attributes.foregroundColor
                    let outlineColor = glyph.attributes.outlineColor
                    let textureCoordinate = glyph.textureCoordinates

                    if let index = textures.firstIndex(where: { $0 === texture }) {
                        textureIndex = index
                    } else {
                        textureIndex += 1
                        textures[textureIndex] = texture
                    }

                    // Apply centering offset before transform
                    let adjustedX1 = glyph.position.x + lineOffsetX
                    let adjustedY1 = glyph.position.y - offsetY
                    let adjustedX2 = glyph.position.z + lineOffsetX
                    let adjustedY2 = glyph.position.w - offsetY

                    verticies.append(
                        GlyphVertexData(
                            position: transform * Vector4(x: adjustedX2, y: adjustedY1, z: 0, w: 1),
                            foregroundColor: foregroundColor,
                            outlineColor: outlineColor,
                            outlineWidth: glyph.attributes.outlineWidth,
                            textureCoordinate: [textureCoordinate.z, textureCoordinate.y],
                            textureIndex: textureIndex
                        )
                    )

                    verticies.append(
                        GlyphVertexData(
                            position: transform * Vector4(x: adjustedX2, y: adjustedY2, z: 0, w: 1),
                            foregroundColor: foregroundColor,
                            outlineColor: outlineColor,
                            outlineWidth: glyph.attributes.outlineWidth,
                            textureCoordinate: [textureCoordinate.z, textureCoordinate.w],
                            textureIndex: textureIndex
                        )
                    )

                    verticies.append(
                        GlyphVertexData(
                            position: transform * Vector4(x: adjustedX1, y: adjustedY2, z: 0, w: 1),
                            foregroundColor: foregroundColor,
                            outlineColor: outlineColor,
                            outlineWidth: glyph.attributes.outlineWidth,
                            textureCoordinate: [textureCoordinate.x, textureCoordinate.w],
                            textureIndex: textureIndex
                        )
                    )

                    verticies.append(
                        GlyphVertexData(
                            position: transform * Vector4(x: adjustedX1, y: adjustedY1, z: 0, w: 1),
                            foregroundColor: foregroundColor,
                            outlineColor: outlineColor,
                            outlineWidth: glyph.attributes.outlineWidth,
                            textureCoordinate: [textureCoordinate.x, textureCoordinate.y],
                            textureIndex: textureIndex
                        )
                    )

                    indeciesCount += 6
                }
            }
        }

        let render = GlyphRenderData(
            transform: transform,
            verticies: verticies,
            indeciesCount: indeciesCount,
            textures: textures
        )

        self.glyphsToRender = render

        return render
    }

    /// Calculates and returns the size.
    public func boundingSize() -> Size {
        if self.textLines.isEmpty {
            return .zero
        }

        var maxWidth: Float = 0
        var totalHeight: Float = 0

        for line in self.textLines {
            maxWidth = max(maxWidth, line.typographicBounds.rect.width)
            totalHeight += line.typographicBounds.rect.height
        }

        return Size(width: maxWidth, height: totalHeight)
    }

    public func visualBounds(for line: TextLine) -> (minX: Float, maxX: Float) {
        var minX = Float.infinity
        var maxX = -Float.infinity

        for run in line {
            for glyph in run {
                minX = min(minX, glyph.position.x)
                maxX = max(maxX, glyph.position.z)
            }
        }

        if minX.isFinite, maxX.isFinite {
            return (minX, maxX)
        }

        let rect = line.typographicBounds.rect
        return (rect.minX, rect.maxX)
    }

    // swiftlint:enable function_body_length
}

public struct Glyph: Sendable, Equatable {
    public let textureAtlas: Texture2D

    /// Coordinates of texturue [x: l, y: b, z: r, w: t]
    public let textureCoordinates: Vector4
    public let attributes: TextAttributeContainer

    /// Position on plane [x: pl, y: pb, z: pr, w: pt]
    public let position: Vector4

    /// Horizontal pen position immediately after this glyph.
    ///
    /// Unlike the visible quad's right edge, this includes typographic advance
    /// for whitespace and side bearings, so it can be used as a caret stop.
    public let advanceX: Float

    public let origin: Point

    /// Size of glyph.
    public let size: Size

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.size == rhs.size
            && lhs.position == rhs.position
            && lhs.advanceX == rhs.advanceX
            && lhs.textureCoordinates == rhs.textureCoordinates
    }
}

public struct GlyphRenderData {
    public var transform: Transform3D
    public var verticies: [GlyphVertexData] = []
    public var indeciesCount: Int = 0
    public var textures: [Texture2D?] = []
}

extension String {
    /// Calculates and returns the size.
    public func boundingSize(width: Float, height: Float, attributes: TextAttributeContainer? = nil) -> Size {
        let attributes = attributes ?? TextAttributeContainer()
        let manager = TextLayoutManager()
        manager.setTextContainer(
            TextContainer(
                text: AttributedText(self, attributes: attributes)
            )
        )
        manager.fitToSize(Size(width: width, height: height))

        return manager.boundingSize()
    }

    /// Returns the bounding box size the receiver occupies when drawn with the given attributes.
    public func size(with attributes: TextAttributeContainer? = nil) -> Size {
        self.boundingSize(width: .infinity, height: .infinity, attributes: attributes)
    }
}

/// A single line in a text layout: a collection of runs of placed glyphs.
public struct TextLine: Equatable {
    let attributedText: Slice<AttributedText>
    let characterRange: Range<String.Index>

    /// All glyphs for render in text contaner bounds
    public internal(set) var runs: [TextRun] = []
    public internal(set) var typographicBounds: TypographicBounds = TypographicBounds()

    init(attributedText: AttributedText, range: Range<String.Index>) {
        self.attributedText = attributedText[range]
        self.characterRange = range
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.runs == rhs.runs && lhs.typographicBounds == rhs.typographicBounds && lhs.characterRange == rhs.characterRange
    }
}

/// The typographic bounds of an element in a text layout.
public struct TypographicBounds: Equatable {
    /// The ascent of the element.
    public internal(set) var ascent: Double = .zero

    /// The descent of the element.
    public internal(set) var descent: Double = .zero

    /// The position of the left edge of the element’s baseline, relative to the text view.
    public var origin: Point {
        rect.origin
    }

    /// Returns a rectangle encapsulating the bounds.
    public internal(set) var rect: Rect

    init() {
        self.rect = .zero
    }
}

extension TextLine: Collection, Sequence {
    public typealias Element = TextRun
    public typealias Index = Int

    public var startIndex: Int {
        self.runs.startIndex
    }

    public var endIndex: Int {
        self.runs.endIndex
    }

    public subscript(position: Int) -> TextRun {
        _read {
            yield self.runs[position]
        }
    }

    public func index(after i: Int) -> Int {
        self.runs.index(after: i)
    }
}

/// A run of placed glyphs in a text layout.
public struct TextRun: Equatable {
    /// All glyphs for render in text contaner bounds
    var glyphs: [Glyph] = []

    public internal(set) var typographicBounds: TypographicBounds = TypographicBounds()
}

extension TextRun: Collection, Sequence {
    public typealias Element = Glyph
    public typealias Index = Int

    public var startIndex: Int {
        self.glyphs.startIndex
    }

    public var endIndex: Int {
        self.glyphs.endIndex
    }

    public subscript(position: Int) -> Glyph {
        _read {
            yield self.glyphs[position]
        }
    }

    public func index(after i: Int) -> Int {
        self.glyphs.index(after: i)
    }
}
