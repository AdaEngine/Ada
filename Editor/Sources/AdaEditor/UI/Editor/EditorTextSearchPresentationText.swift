@_spi(AdaEngine) import AdaEngine
import Foundation

enum EditorTextSearchPresentationText {
    static func attributedText(
        _ match: EditorTextSearchMatch,
        palette: EditorCodeColorPalette,
        font: Font,
        keywordFont: Font
    ) -> AttributedText {
        let source = match.lineText
        let nsRange = NSRange(
            location: match.range.start.character,
            length: max(0, match.range.end.character - match.range.start.character)
        )
        guard let matchRange = Range(nsRange, in: source) else {
            return AttributedText(String(source.prefix(240)))
        }
        // Keep a bounded excerpt around the match, including matches deep inside generated JSON.
        let start = source.index(matchRange.lowerBound, offsetBy: -60, limitedBy: source.startIndex) ?? source.startIndex
        let end = source.index(matchRange.upperBound, offsetBy: 160, limitedBy: source.endIndex) ?? source.endIndex
        let prefix = start == source.startIndex ? "" : "… "
        let excerpt = prefix + source[start..<end] + (end == source.endIndex ? "" : " …")
        let extensionName = URL(fileURLWithPath: match.relativePath).pathExtension.lowercased()
        let language: EditorSourceLanguage
        if ["ascn", "scene", "ui"].contains(extensionName) {
            let first = source.trimmingCharacters(in: .whitespaces).first
            language = first == "\"" || first == "{" || first == "[" ? .json : .yaml
        } else {
            language = .detect(fileName: match.relativePath)
        }
        var text = EditorSourceHoverPresentation.attributedText(
            excerpt,
            language: language,
            palette: palette,
            font: font,
            keywordFont: keywordFont
        )
        let selectionStart = excerpt.index(excerpt.startIndex, offsetBy: prefix.count + source.distance(from: start, to: matchRange.lowerBound))
        let selectionEnd = excerpt.index(selectionStart, offsetBy: source.distance(from: matchRange.lowerBound, to: matchRange.upperBound))
        for index in excerpt[selectionStart..<selectionEnd].indices {
            var attributes = text.attributes(at: index)
            attributes.backgroundColor = palette.selection
            text.setAttributes(attributes, at: index)
        }
        return text
    }
}
