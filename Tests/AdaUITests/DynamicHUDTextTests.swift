@_spi(Internal) @testable import AdaUI
@testable import AdaRender
import Foundation
import Math
import Testing

@MainActor
@Suite(.serialized)
struct DynamicHUDTextTests {
    @Test func emptyBindingGetsNonzeroGeometryWhenTextArrives() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let context = UIBindingContext(values: ["bag": .string("")])
        let document = UISceneDocument(root: .init(type: "FreeLayout", children: [
            .init(type: "Text", arguments: ["text": .init(binding: "bag")])
        ]), inputs: [.init("bag", type: .string, defaultValue: .string(""))])
        let session = try UISceneInstance(document: document, context: context)
        let container = UIContainerView(rootView: UISceneView(session: session))
        container.frame = Rect(x: 0, y: 0, width: 800, height: 600)
        container.layoutSubviews()
        let message = "РЮКЗАК\n1. Образец заражённой ткани\n2 / 8 · 10 / 16 кг"
        context.set("bag", to: .string(message))
        for _ in 0..<8 {
            await Task.yield()
            container.updateHierarchy(1.0 / 60)
        }
        func find(_ node: ViewNode) -> ViewNode? {
            if (node.content as? Text)?.plainText == message { return node }
            return node.transientEnvironmentChildren.lazy.compactMap(find).first
        }
        let text = try #require(find(container.viewTree.rootNode))
        #expect(text.frame.width > 100 && text.frame.height > 30, "\(text.frame)")
    }
}
