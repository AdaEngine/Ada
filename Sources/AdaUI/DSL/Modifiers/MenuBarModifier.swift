//
//  MenuBarModifier.swift
//  AdaEngine
//

import AdaInput
import AdaText
import AdaUtils

/// Attaches application menus to a view subtree.
///
/// Menu content is collected by ``UIMenuBuilder`` when the platform window builds its menu bar.
extension View {
    public func menuBar(_ menus: [UIMenu], foregroundColor: Color? = nil, backgroundColor: Color? = nil) -> some View {
        modifier(MenuBarModifier(content: self, menus: menus, foregroundColor: foregroundColor, backgroundColor: backgroundColor))
    }

    public func menuBar(_ menus: UIMenu...) -> some View {
        menuBar(menus)
    }
}

private struct MenuBarModifier<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let content: Content
    let menus: [UIMenu]
    let foregroundColor: Color?
    let backgroundColor: Color?

    func buildViewNode(in context: BuildContext) -> ViewNode {
        #if os(Windows) || os(Linux)
        let contentNode = context.makeNode(from: VStack(spacing: 0) {
            WindowMenuBar(menus: menus, foregroundColor: foregroundColor, backgroundColor: backgroundColor)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .keyboardShortcuts(WindowMenuBar.shortcuts(for: menus)))
        #else
        let contentNode = context.makeNode(from: content)
        #endif
        return MenuBarModifierNode(
            contentNode: contentNode,
            content: content,
            menus: menus
        )
    }
}

#if os(Windows) || os(Linux)
/// Desktop platforms without an application menu use the same command model
/// in a window menu row. Popup interaction and dismissal stay in AdaUI.
private struct WindowMenuBar: View {
    let menus: [UIMenu]
    let foregroundColor: Color?
    let backgroundColor: Color?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.windowCaption) private var caption

    var body: some View {
        HStack(spacing: 0) {
            ForEach(menus) { menu in
                Group {
                    if let image = menu.image {
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                    } else {
                        Text(menu.title)
                            .font(.system(size: 12))
                    }
                }
                    .padding(.horizontal, 10)
                    .frame(height: caption.isVisible ? 32 : 26)
                    .contextMenu(opensOnPrimaryAction: true) {
                        WindowMenuItems(items: menu.items)
                    }
                    .accessibilityIdentifier("AdaUI.MenuBar." + menu.id)
            }
            Spacer(minLength: 0)
            WindowCaptionControls()
        }
        .frame(maxWidth: .infinity)
        .foregroundColor(foregroundColor ?? (colorScheme == .dark ? .white : .black))
        .background(backgroundColor ?? Color.gray.opacity(0.12))
        .accessibilityIdentifier("AdaUI.MenuBar")
    }

    #if os(Windows) || os(Linux)
    static func shortcuts(for menus: [UIMenu]) -> [KeyboardShortcutAction] {
        menus.flatMap(\.items)
            .filter { $0.keyEquivalent != nil && $0.action != nil }
            .sorted { ($0.keyEquivalentModifierMask?.rawValue.nonzeroBitCount ?? 0) > ($1.keyEquivalentModifierMask?.rawValue.nonzeroBitCount ?? 0) }
            .compactMap { item in
                guard let key = item.keyEquivalent else { return nil }
                return KeyboardShortcutAction(key, modifiers: item.keyEquivalentModifierMask ?? []) {
                    if item.isEnabled { item.action?() }
                }
            }
    }
    #endif
}

private struct WindowMenuItems: View, ContextMenuItemsConvertible {
    let items: [MenuItem]

    var contextMenuItems: [ContextMenuItemDescription] {
        items.compactMap { item in
            guard item.isSeparator || item.isEnabled else { return nil }
            return ContextMenuItemDescription(
                title: item.title,
                action: item.action.map { action in { action() } },
                submenu: item.submenu.map { WindowMenuItems(items: $0.items).contextMenuItems } ?? [],
                isSeparator: item.isSeparator
            )
        }
    }

    var body: some View {
        ForEach(items) { item in
            if item.isSeparator {
                Divider()
            } else if let submenu = item.submenu {
                ContextMenuSubmenu(item.title) {
                    WindowMenuItems(items: submenu.items)
                }
            } else {
                Button(item.title) { item.action?() }
                    .disabled(!item.isEnabled)
            }
        }
    }
}
#endif

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
