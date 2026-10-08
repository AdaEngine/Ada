import AdaUIDescription

struct UISceneIdentity<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never
    let content: Content
    let nodeID: String

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let node = ViewModifierNode(contentNode: context.makeNode(from: content), content: content)
        node.uiSceneNodeID = nodeID
        return node
    }
}
