@_spi(AdaEngine) import AdaEngine
import Math
import Testing

@testable import AdaUI

@Suite("Code scroll indicators", .serialized)
@MainActor
struct EditorCodeScrollIndicatorTests {
    @Test("Text editors show both indicators for overflowing content and move them with scrolling")
    func overflowingEditor() throws {
        prepareRenderer()
        let text = Array(repeating: String(repeating: "x", count: 200), count: 100).joined(separator: "\n")
        let container = UIContainerView(rootView: TextEditor(text: .constant(text)))
        container.frame = Rect(x: 0, y: 0, width: 240, height: 160)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let scroll = try #require(findScroll(container.viewTree.rootNode))
        let before = scroll.scrollIndicatorRects
        #expect(before.count == 2)
        for rect in before {
            #expect(rect.minX >= 0 && rect.maxX <= scroll.frame.width)
            #expect(rect.minY >= 0 && rect.maxY <= scroll.frame.height)
        }
        #expect(scroll.scrollToVisibleRect(Rect(x: 1000, y: 1000, width: 10, height: 10), in: scroll))
        let after = scroll.scrollIndicatorRects
        #expect(after[0].minY > before[0].minY)
        #expect(after[1].minX > before[1].minX)
    }

    @Test("Short documents do not show scroll indicators")
    func shortEditor() throws {
        prepareRenderer()
        let container = UIContainerView(rootView: TextEditor(text: .constant("hello")))
        container.frame = Rect(x: 0, y: 0, width: 400, height: 300)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        #expect(try #require(findScroll(container.viewTree.rootNode)).scrollIndicatorRects.isEmpty)
    }

    private func prepareRenderer() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "CodeScrollIndicators")))
        }
    }

    private func findScroll(_ node: ViewNode) -> ScrollViewNode? {
        if let scroll = node as? ScrollViewNode {
            return scroll
        }
        if let root = node as? ViewRootNode {
            return findScroll(root.contentNode)
        }
        if let modifier = node as? ViewModifierNode {
            return findScroll(modifier.contentNode)
        }
        if let container = node as? ViewContainerNode {
            for child in container.nodes {
                if let scroll = findScroll(child) {
                    return scroll
                }
            }
        }
        return nil
    }
}
