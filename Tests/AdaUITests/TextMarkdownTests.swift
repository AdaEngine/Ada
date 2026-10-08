import Testing
import AdaText
@testable import AdaPlatform
import AdaUtils
@testable import AdaUI

@MainActor
struct TextMarkdownTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func stringInitializerKeepsMarkdownLiteral() {
        let text = Text("**Hello**")

        #expect(text.storage.text.text == "**Hello**")
    }

    @Test
    func markdownInitializerBuildsAttributedStorage() {
        let text = Text(markdown: "**Hello**")

        #expect(text.storage.text.text == "Hello")
        #expect(firstAttributes(in: text.storage.text).fontTraits == TextFontTraits.strong)
    }

    @Test
    func environmentFontPreservesMarkdownTraitsAndScale() {
        let text = Text(markdown: "# Hello")
        var environment = EnvironmentValues()
        environment.font = Font.system(size: 20)

        let attributedText = text.storage.applyingEnvironment(environment)
        let attributes = firstAttributes(in: attributedText)

        #expect(attributes.fontTraits == TextFontTraits.strong)
        #expect(attributes.fontScale == 1.6)
        #expect(attributes.font.pointSize == 32)
    }

    @Test
    func attributedTextInitializerPreservesExplicitRunColors() {
        var firstAttributes = TextAttributeContainer()
        firstAttributes.foregroundColor = .red

        var secondAttributes = TextAttributeContainer()
        secondAttributes.foregroundColor = .blue

        var source = AttributedText("red", attributes: firstAttributes)
        source += AttributedText(" blue", attributes: secondAttributes)

        let text = Text(source)
        var environment = EnvironmentValues()
        environment.foregroundColor = .black

        let attributedText = text.storage.applyingEnvironment(environment)

        #expect(attributedText.attributes(at: attributedText.startIndex).foregroundColor == .red)
        #expect(attributedText.attributes(at: attributedText.text.index(before: attributedText.endIndex)).foregroundColor == .blue)
    }

    @Test
    func foregroundColorModifierStillOverridesAttributedTextRunColors() {
        var attributes = TextAttributeContainer()
        attributes.foregroundColor = .red

        let text = Text(AttributedText("red", attributes: attributes))
            .foregroundColor(.blue)

        let attributedText = text.storage.applyingEnvironment(EnvironmentValues())

        #expect(firstAttributes(in: attributedText).foregroundColor == .blue)
    }

    private func firstAttributes(in text: AttributedText) -> TextAttributeContainer {
        text.attributes(at: text.startIndex)
    }
}
