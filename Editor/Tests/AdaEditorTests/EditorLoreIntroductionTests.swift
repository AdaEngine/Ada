@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@MainActor
extension EditorLocalizationTests {
    @Test("Lore information fits both languages and opens the official documentation")
    func loreIntroduction() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "LoreIntroduction")))
        }
        let previous = EditorLocalization.shared.preference
        defer { EditorLocalization.shared.preference = previous }
        var opened: [URL] = []
        let container = UIContainerView(rootView: EditorLoreIntroduction(openURL: { opened.append($0); return true }).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 300, height: 180)
        container.bounds.size = container.frame.size
        for language in [EditorLanguage.english, .russian] {
            EditorLocalization.shared.preference = language
            for _ in 0..<10 { await Task.yield(); container.update(1 / 60); container.layoutIfNeeded() }
            let link = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Lore.LearnMore"))
            #expect(link.absoluteFrame.minX >= 0 && link.absoluteFrame.maxX <= 300)
            #expect(link.absoluteFrame.minY >= 0 && link.absoluteFrame.maxY <= 180)
        }
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Lore.LearnMore"))
        #expect(opened.map(\.absoluteString) == [EditorLoreInformation.documentationURL])
    }
}
