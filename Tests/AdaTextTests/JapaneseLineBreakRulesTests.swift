import Testing
@testable import AdaText

struct JapaneseLineBreakRulesTests {

    @Test
    func japaneseTextAllowsBreaksBetweenOrdinaryCharacters() {
        let text = "日本語"
        let index = text.index(after: text.startIndex)

        #expect(TextLineBreakRules.isJapaneseWrappingContext(
            at: index,
            in: text,
            rowStartIndex: text.startIndex
        ))
        #expect(TextLineBreakRules.canBreakJapaneseLine(
            before: index,
            in: text,
            rowStartIndex: text.startIndex
        ))
    }

    @Test
    func japaneseClosingPunctuationDoesNotStartWrappedLine() {
        let text = "日本語。"
        let periodIndex = text.index(before: text.endIndex)

        #expect(!TextLineBreakRules.canBreakJapaneseLine(
            before: periodIndex,
            in: text,
            rowStartIndex: text.startIndex
        ))
    }

    @Test
    func japaneseOpeningPunctuationStaysWithFollowingCharacter() {
        let text = "「世界"
        let secondIndex = text.index(after: text.startIndex)

        #expect(!TextLineBreakRules.canBreakJapaneseLine(
            before: secondIndex,
            in: text,
            rowStartIndex: text.startIndex
        ))
    }

    @Test
    func japaneseOpeningPunctuationDoesNotStartWrappedLine() {
        let text = "日本「語"
        let openingIndex = text.index(text.startIndex, offsetBy: 2)

        #expect(!TextLineBreakRules.canBreakJapaneseLine(
            before: openingIndex,
            in: text,
            rowStartIndex: text.startIndex
        ))
    }

    @Test
    func smallKanaAndProlongedSoundMarkDoNotStartWrappedLine() {
        let smallKanaText = "キゃ"
        let smallKanaIndex = smallKanaText.index(after: smallKanaText.startIndex)

        #expect(!TextLineBreakRules.canBreakJapaneseLine(
            before: smallKanaIndex,
            in: smallKanaText,
            rowStartIndex: smallKanaText.startIndex
        ))

        let soundMarkText = "メー"
        let soundMarkIndex = soundMarkText.index(after: soundMarkText.startIndex)

        #expect(!TextLineBreakRules.canBreakJapaneseLine(
            before: soundMarkIndex,
            in: soundMarkText,
            rowStartIndex: soundMarkText.startIndex
        ))
    }
}
