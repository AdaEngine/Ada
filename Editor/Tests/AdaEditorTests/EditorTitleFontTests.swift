@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import Math
import Testing

@testable import AdaEditor

@MainActor
@Suite(.serialized)
struct EditorTitleFontTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "TitleFontTests")))
        }
    }

    @Test
    func bundledCalSansRendersNavigationTitleOnly() throws {
        let font = AdaEditorTitleFont.font(size: 22)
        #expect(font.name.contains("Cal"))

        let container = UIContainerView(
            rootView: NavigationStack {
                Text("Body")
                    .accessibilityIdentifier("body")
                    .navigationTitle("New Project")
                    .navigationTitleFont(font)
                    .navigationTitlePosition(.leading)
                    .navigationBarTrailingItems {
                        Text("Action")
                            .accessibilityIdentifier("action")
                    }
            }
        )
        container.frame = Rect(x: 0, y: 0, width: 600, height: 400)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        let title = try #require(
            container.viewTree.rootNode.findNodyByAccessibilityIdentifier("AdaUI.NavigationBar.Title") as? TextViewNode
        )
        let glyphs = title.layoutManager.textLines.flatMap { $0.flatMap { Array($0) } }
        #expect(!glyphs.isEmpty)
        #expect(glyphs.allSatisfy { $0.attributes.font == font })
        #expect(title.frame.size.height > 0)

        for identifier in ["body", "action"] {
            let node = try #require(container.viewTree.rootNode.findNodyByAccessibilityIdentifier(identifier) as? TextViewNode)
            _ = node.sizeThatFits(.infinity)
            let glyphs = node.layoutManager.textLines.flatMap { $0.flatMap { Array($0) } }
            #expect(!glyphs.isEmpty)
            #expect(glyphs.allSatisfy { $0.attributes.font.name != font.name })
        }
    }

    @Test
    func nilNavigationTitleFontKeepsDefaultSize() throws {
        let container = UIContainerView(
            rootView: NavigationStack {
                Color.clear
                    .navigationTitle("Settings")
                    .navigationTitlePosition(.leading)
                    .navigationTitleFont(nil)
            }
        )
        container.frame = Rect(x: 0, y: 0, width: 600, height: 400)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        let title = try #require(
            container.viewTree.rootNode.findNodyByAccessibilityIdentifier("AdaUI.NavigationBar.Title") as? TextViewNode
        )
        let glyphs = title.layoutManager.textLines.flatMap { $0.flatMap { Array($0) } }
        #expect(!glyphs.isEmpty)
        #expect(glyphs.allSatisfy { $0.attributes.font == .system(size: 22) })
    }
}
