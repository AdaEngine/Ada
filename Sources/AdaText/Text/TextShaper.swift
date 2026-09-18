import AdaTextShaper
import Foundation

struct ShapedGlyph: Equatable {
    let glyphIndex: Int32
    let cluster: Int
    let xAdvance: Double
    let yAdvance: Double
    let xOffset: Double
    let yOffset: Double
}

enum TextShaper {
    private enum Direction {
        case leftToRight
        case rightToLeft
    }

    private struct DirectionalRun {
        let range: Range<String.Index>
        let direction: Direction
        let utf8Offset: Int
    }

    static func shape(
        _ text: String,
        font: FontResource,
        writingDirection: TextWritingDirection = .natural
    ) -> [ShapedGlyph] {
        guard !text.isEmpty, let fontPath = font.handle.fontPath else {
            return []
        }

        let runs = directionalRuns(in: text, writingDirection: writingDirection)
        return runs.flatMap { run in
            shapeRun(
                String(text[run.range]),
                fontPath: fontPath.path,
                font: font,
                direction: run.direction,
                clusterOffset: run.utf8Offset
            )
        }
    }

    private static func shapeRun(
        _ text: String,
        fontPath: String,
        font: FontResource,
        direction: Direction,
        clusterOffset: Int
    ) -> [ShapedGlyph] {
        let utf8Count = text.utf8.count
        guard utf8Count > 0 else {
            return []
        }

        let variationAxes = font.handle.variationAxes.map { axis in
            ada_font_variation_axis_t(tag: axis.tag, value: axis.value)
        }
        let shapedText = fontPath.withCString { fontPathPointer in
            text.withCString { textPointer in
                unsafe variationAxes.withUnsafeBufferPointer { axes in
                    unsafe ada_text_shape_utf8_with_direction_and_variations(
                        fontPathPointer,
                        textPointer,
                        Int32(utf8Count),
                        direction == .rightToLeft
                            ? ADA_TEXT_DIRECTION_RIGHT_TO_LEFT
                            : ADA_TEXT_DIRECTION_LEFT_TO_RIGHT,
                        axes.baseAddress,
                        Int32(axes.count)
                    )
                }
            }
        }

        guard let shapedText else {
            return []
        }

        defer {
            unsafe ada_shaped_text_destroy(shapedText)
        }

        let shapedTextValue = unsafe shapedText.pointee
        guard shapedTextValue.glyphCount > 0, let glyphs = shapedTextValue.glyphs else {
            return []
        }

        return (0..<Int(shapedTextValue.glyphCount))
            .map { index in
                let glyph = unsafe glyphs[index]
                return ShapedGlyph(
                    glyphIndex: Int32(glyph.glyphIndex),
                    cluster: Int(glyph.cluster) + clusterOffset,
                    xAdvance: glyph.xAdvance,
                    yAdvance: glyph.yAdvance,
                    xOffset: glyph.xOffset,
                    yOffset: glyph.yOffset
                )
            }
    }

    private static func directionalRuns(
        in text: String,
        writingDirection: TextWritingDirection
    ) -> [DirectionalRun] {
        let characters = text.indices.map { index in
            (index: index, direction: strongDirection(of: text[index]))
        }
        guard !characters.isEmpty else {
            return []
        }

        let baseDirection: Direction =
            switch writingDirection {
            case .leftToRight: .leftToRight
            case .rightToLeft: .rightToLeft
            case .natural: characters.lazy.compactMap(\.direction).first ?? .leftToRight
            }

        var nextStrongDirections = [Direction?](repeating: nil, count: characters.count)
        var nextStrongDirection: Direction?
        for index in characters.indices.reversed() {
            nextStrongDirections[index] = nextStrongDirection
            if let direction = characters[index].direction {
                nextStrongDirection = direction
            }
        }

        var precedingStrongDirection: Direction?
        let resolvedDirections = characters.indices.map { index in
            if let direction = characters[index].direction {
                precedingStrongDirection = direction
                return direction
            }

            let following = nextStrongDirections[index]
            return precedingStrongDirection == following ? (precedingStrongDirection ?? baseDirection) : baseDirection
        }

        var runs: [DirectionalRun] = []
        var runStart = 0
        for index in 1...characters.count {
            guard index == characters.count || resolvedDirections[index] != resolvedDirections[runStart] else {
                continue
            }

            let lowerBound = characters[runStart].index
            let upperBound = index == characters.count ? text.endIndex : characters[index].index
            runs.append(
                DirectionalRun(
                    range: lowerBound..<upperBound,
                    direction: resolvedDirections[runStart],
                    utf8Offset: text[..<lowerBound].utf8.count
                )
            )
            runStart = index
        }

        return baseDirection == .rightToLeft ? Array(runs.reversed()) : runs
    }

    private static func strongDirection(of character: Character) -> Direction? {
        for scalar in character.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .decimalNumber,
                .letterNumber,
                .otherNumber:
                return .leftToRight
            default:
                break
            }

            if isRightToLeft(scalar.value) {
                return .rightToLeft
            }

            switch scalar.properties.generalCategory {
            case .uppercaseLetter,
                .lowercaseLetter,
                .titlecaseLetter,
                .modifierLetter,
                .otherLetter:
                return .leftToRight
            default:
                continue
            }
        }
        return nil
    }

    private static func isRightToLeft(_ value: UInt32) -> Bool {
        (0x0590...0x08FF).contains(value)
            || (0xFB1D...0xFDFF).contains(value)
            || (0xFE70...0xFEFF).contains(value)
            || (0x10800...0x10FFF).contains(value)
            || (0x1E800...0x1EEFF).contains(value)
    }
}
