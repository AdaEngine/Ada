//
//  MenuBarModifier.swift
//  AdaEngine
//

/// Attaches application menus to a view subtree.
///
/// Menu content is collected by ``UIMenuBuilder`` when the platform window builds its menu bar.
extension View {
    public func menuBar(_ menus: [UIMenu]) -> some View {
        modifier(MenuBarModifier(content: self, menus: menus))
    }

    public func menuBar(_ menus: UIMenu...) -> some View {
        menuBar(menus)
    }
}

private struct MenuBarModifier<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let content: Content
    let menus: [UIMenu]

    func buildViewNode(in context: BuildContext) -> ViewNode {
        MenuBarModifierNode(
            contentNode: context.makeNode(from: content),
            content: content,
            menus: menus
        )
    }
}

private final class MenuBarModifierNode: ViewModifierNode {
    private var menus: [UIMenu]

    init(contentNode: ViewNode, content: some View, menus: [UIMenu]) {
        self.menus = menus
        super.init(contentNode: contentNode, content: content)
    }

    override func update(from newNode: ViewNode) {
        guard let otherNode = newNode as? MenuBarModifierNode else {
            return
        }

        self.menus = otherNode.menus
        super.update(from: otherNode)
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        for menu in menus {
            builder.insert(menu)
        }

        super.buildMenu(with: builder)
    }
}
