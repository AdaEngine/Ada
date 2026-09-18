//
//  KeyboardShortcutModifier.swift
//  AdaEngine
//

import AdaInput
import AdaUtils
import Math

// MARK: - KeyModifier alias (SwiftUI-style naming)

extension KeyModifier {
    /// Command (⌘) on Apple platforms; maps to ``KeyModifier/main``.
    public static let command = KeyModifier.main
}

// MARK: - Character → KeyCode

enum KeyboardShortcutKeyParsing {
    static func keyCode(forCharacter char: Character) -> KeyCode? {
        let lower = String(char).lowercased()
        guard lower.count == 1, let u8 = lower.utf8.first else {
            return nil
        }
        if u8 >= 97, u8 <= 122 {
            return KeyCode(rawValue: lower)
        }
        if u8 >= 48, u8 <= 57 {
            switch u8 {
            case 48: return .num0
            case 49: return .num1
            case 50: return .num2
            case 51: return .num3
            case 52: return .num4
            case 53: return .num5
            case 54: return .num6
            case 55: return .num7
            case 56: return .num8
            case 57: return .num9
            default: return nil
            }
        }
        return nil
    }

    static func matchesModifiers(event: KeyEvent, required: KeyModifier) -> Bool {
        guard required.isSubset(of: event.modifiers) else {
            return false
        }
        if required.isEmpty {
            let blockers: KeyModifier = [.main, .control, .alt]
            return event.modifiers.isDisjoint(with: blockers)
        }
        return true
    }
}

// MARK: - First primary target (button)

enum KeyboardShortcutTargetFinder {
    /// Depth-first, first enabled ``ButtonViewNode`` in subtree (matches focus traversal order for stacks).
    @MainActor
    static func firstEnabledButton(in node: ViewNode) -> ButtonViewNode? {
        if let button = node as? ButtonViewNode {
            return button.canBecomeFocused ? button : nil
        }
        if let root = node as? ViewRootNode {
            return firstEnabledButton(in: root.contentNode)
        }
        if let container = node as? ViewContainerNode {
            for child in container.nodes {
                if let found = firstEnabledButton(in: child) {
                    return found
                }
            }
            return nil
        }
        if let nav = node as? NavigationStackNode {
            return firstEnabledButton(in: nav.shortcutContentSubtree)
        }
        if let modifier = node as? ViewModifierNode {
            return firstEnabledButton(in: modifier.contentNode)
        }
        return nil
    }
}

// MARK: - Registry host

@MainActor
protocol KeyboardShortcutHandling: AnyObject {
    func handleShortcutIfNeeded(event: KeyEvent) -> Bool
}

@MainActor
protocol KeyboardShortcutRegistering: AnyObject {
    func registerKeyboardShortcut(target: any KeyboardShortcutHandling)
    func unregisterKeyboardShortcut(target: any KeyboardShortcutHandling)
}

// MARK: - Modifier node

@MainActor
final class KeyboardShortcutModifierNode: ViewModifierNode, KeyboardShortcutHandling {
    private(set) var keyCode: KeyCode
    private(set) var requiredModifiers: KeyModifier
    private var explicitAction: (() -> Void)?
    private weak var shortcutRegistrationHost: KeyboardShortcutRegistering?

    init(
        contentNode: ViewNode,
        content: some View,
        keyCode: KeyCode,
        requiredModifiers: KeyModifier,
        explicitAction: (() -> Void)?
    ) {
        self.keyCode = keyCode
        self.requiredModifiers = requiredModifiers
        self.explicitAction = explicitAction
        super.init(contentNode: contentNode, content: content)
    }

    override func update(from newNode: ViewNode) {
        guard let other = newNode as? KeyboardShortcutModifierNode else {
            return
        }
        self.keyCode = other.keyCode
        self.requiredModifiers = other.requiredModifiers
        self.explicitAction = other.explicitAction
        super.update(from: other)
    }

    override func updateViewOwner(_ owner: ViewOwner) {
        self.shortcutRegistrationHost?.unregisterKeyboardShortcut(target: self)
        self.shortcutRegistrationHost = nil
        super.updateViewOwner(owner)
        if let host = owner as? KeyboardShortcutRegistering {
            host.registerKeyboardShortcut(target: self)
            self.shortcutRegistrationHost = host
        }
    }

    override func didMove(to parent: ViewNode?) {
        super.didMove(to: parent)
        guard parent == nil else {
            return
        }
        shortcutRegistrationHost?.unregisterKeyboardShortcut(target: self)
        shortcutRegistrationHost = nil
    }

    /// Returns `true` if the shortcut was handled (action ran).
    func handleShortcutIfNeeded(event: KeyEvent) -> Bool {
        guard event.status == .down else {
            return false
        }
        guard event.keyCode == keyCode else {
            return false
        }
        guard KeyboardShortcutKeyParsing.matchesModifiers(event: event, required: requiredModifiers) else {
            return false
        }
        if let explicitAction {
            explicitAction()
            return true
        }
        if let button = KeyboardShortcutTargetFinder.firstEnabledButton(in: contentNode) {
            button.performPrimaryActionForShortcut()
            return true
        }
        return false
    }
}

public struct KeyboardShortcutAction {
    let keyCode: KeyCode
    let requiredModifiers: KeyModifier
    let action: () -> Void

    public init(
        _ keyCode: KeyCode,
        modifiers: KeyModifier = [],
        action: @escaping () -> Void
    ) {
        self.keyCode = keyCode
        self.requiredModifiers = modifiers
        self.action = action
    }

    public init?(
        _ key: Character,
        modifiers: KeyModifier = [],
        action: @escaping () -> Void
    ) {
        guard let keyCode = KeyboardShortcutKeyParsing.keyCode(forCharacter: key) else {
            return nil
        }

        self.init(keyCode, modifiers: modifiers, action: action)
    }
}

@MainActor
final class KeyboardShortcutsModifierNode: ViewModifierNode, KeyboardShortcutHandling {
    private var shortcuts: [KeyboardShortcutAction]
    private weak var shortcutRegistrationHost: KeyboardShortcutRegistering?

    init(
        contentNode: ViewNode,
        content: some View,
        shortcuts: [KeyboardShortcutAction]
    ) {
        self.shortcuts = shortcuts
        super.init(contentNode: contentNode, content: content)
    }

    override func update(from newNode: ViewNode) {
        guard let other = newNode as? KeyboardShortcutsModifierNode else {
            return
        }

        self.shortcuts = other.shortcuts
        super.update(from: other)
    }

    override func updateViewOwner(_ owner: ViewOwner) {
        self.shortcutRegistrationHost?.unregisterKeyboardShortcut(target: self)
        self.shortcutRegistrationHost = nil
        super.updateViewOwner(owner)
        if let host = owner as? KeyboardShortcutRegistering {
            host.registerKeyboardShortcut(target: self)
            self.shortcutRegistrationHost = host
        }
    }

    override func didMove(to parent: ViewNode?) {
        super.didMove(to: parent)
        guard parent == nil else {
            return
        }
        shortcutRegistrationHost?.unregisterKeyboardShortcut(target: self)
        shortcutRegistrationHost = nil
    }

    func handleShortcutIfNeeded(event: KeyEvent) -> Bool {
        guard event.status == .down else {
            return false
        }

        for shortcut in shortcuts {
            guard event.keyCode == shortcut.keyCode else {
                continue
            }
            guard KeyboardShortcutKeyParsing.matchesModifiers(event: event, required: shortcut.requiredModifiers) else {
                continue
            }

            shortcut.action()
            return true
        }

        return false
    }
}

// MARK: - ViewModifier + View extension

struct KeyboardShortcutViewModifier<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let content: Content
    let keyCode: KeyCode
    let requiredModifiers: KeyModifier
    let explicitAction: (() -> Void)?

    func buildViewNode(in context: BuildContext) -> ViewNode {
        KeyboardShortcutModifierNode(
            contentNode: context.makeNode(from: content),
            content: content,
            keyCode: keyCode,
            requiredModifiers: requiredModifiers,
            explicitAction: explicitAction
        )
    }
}

struct KeyboardShortcutsViewModifier<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let content: Content
    let shortcuts: [KeyboardShortcutAction]

    func buildViewNode(in context: BuildContext) -> ViewNode {
        KeyboardShortcutsModifierNode(
            contentNode: context.makeNode(from: content),
            content: content,
            shortcuts: shortcuts
        )
    }
}

extension View {
    /// Associates a keyboard shortcut with this view.
    ///
    /// If `action` is `nil`, the shortcut triggers the first enabled ``Button`` in the modified subtree (depth-first),
    /// matching SwiftUI-style container behavior.
    ///
    /// Shortcuts are dispatched from ``UIContainerView`` before focused key handling (see plan: global slide navigation).
    @ViewBuilder
    public func keyboardShortcut(
        _ key: Character,
        modifiers: KeyModifier = [],
        action: (() -> Void)? = nil
    ) -> some View {
        if let keyCode = KeyboardShortcutKeyParsing.keyCode(forCharacter: key) {
            modifier(
                KeyboardShortcutViewModifier(
                    content: self,
                    keyCode: keyCode,
                    requiredModifiers: modifiers,
                    explicitAction: action
                )
            )
        } else {
            self
        }
    }

    /// Associates a keyboard shortcut using a ``KeyCode`` (e.g. arrow keys).
    public func keyboardShortcut(
        _ keyCode: KeyCode,
        modifiers: KeyModifier = [],
        action: (() -> Void)? = nil
    ) -> some View {
        modifier(
            KeyboardShortcutViewModifier(
                content: self,
                keyCode: keyCode,
                requiredModifiers: modifiers,
                explicitAction: action
            )
        )
    }

    /// Associates multiple explicit keyboard shortcut actions with this view using a single modifier node.
    public func keyboardShortcuts(_ shortcuts: [KeyboardShortcutAction]) -> some View {
        modifier(
            KeyboardShortcutsViewModifier(
                content: self,
                shortcuts: shortcuts
            )
        )
    }
}
