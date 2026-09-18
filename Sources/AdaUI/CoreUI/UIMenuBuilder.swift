//
//  UIMenuBuilder.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 04.08.2024.
//

import AdaInput
import AdaRender
import AdaUtils

/// A protocol that represents a menu builder.
@MainActor
public protocol UIMenuBuilder: AnyObject {
    /// Insert a new menu.
    ///
    /// - Parameter menu: The menu to insert.
    func insert(_ menu: UIMenu)

    /// Remove a menu.
    ///
    /// - Parameter menu: The menu to remove.
    func remove(_ menu: UIMenu.ID)

    /// Set the menu builder needs update.
    func setNeedsUpdate()

    /// Update the menu builder if needed.
    func updateIfNeeded()
}

/// A custom item in the editing menu managed by the menu controller.
///
/// Custom menu items appear in the menu after any validated system items.
/// A ``MenuItem`` object has two properties: a title and an action block identifying the method to invoke in the handling responder object.
/// To have custom menu items appear in the menu, you must add them to the ``UIMenuBuilder/insert(_:)`` method.
@MainActor
public final class MenuItem: Identifiable {
    /// A separator item title.
    private static let separatorTitle = "_SEPARATOR_"

    /// A separator item.
    public static let separator: MenuItem = MenuItem()

    /// The menu item’s title.
    public let title: String
    /// The menu item’s image.
    public var image: Image?

    /// The menu item’s action.
    public var action: UIEventAction?

    /// The menu item’s key equivalent.
    public var keyEquivalent: KeyCode?
    /// The menu item’s key equivalent modifier mask.
    public var keyEquivalentModifierMask: KeyModifier?

    /// A Boolean value indicating whether the menu item is enabled.
    public var isEnabled: Bool = true

    /// The menu that owns the menu item.
    public private(set) weak var menu: UIMenu?

    /// A Boolean value indicating whether the menu item is a separator.
    public var isSeparator: Bool {
        self.title == Self.separatorTitle
    }

    init() {
        self.title = Self.separatorTitle
        self.isEnabled = false
    }

    /// Initialize a new menu item.
    ///
    /// - Parameters:
    ///   - title: The menu item’s title.
    ///   - image: The menu item’s image.
    ///   - action: The menu item’s action.
    ///   - keyEquivalent: The menu item’s key equivalent.
    public init(
        title: String,
        image: Image? = nil,
        action: UIEventAction? = nil,
        keyEquivalent: KeyCode? = nil,
        keyEquivalentModifierMask: KeyModifier? = nil
    ) {
        self.title = title
        self.image = image
        self.action = action
        self.keyEquivalent = keyEquivalent
        self.keyEquivalentModifierMask = keyEquivalentModifierMask
    }

    func setMenuOwner(_ owner: UIMenu) {
        self.menu = owner
    }

    /// The parent menu item.
    public private(set) weak var parent: MenuItem?

    /// A Boolean value indicating whether the menu item has a submenu.
    public var hasSubmenu: Bool {
        return submenu != nil
    }

    /// The submenu.
    public private(set) var submenu: UIMenu?

    /// Set the submenu.
    public func setSebmenu(_ menu: UIMenu) {
        self.submenu = menu
        menu.items.forEach {
            $0.parent = self
        }
    }

    /// Remove the submenu.
    public func removeSubmenu() {
        self.submenu = nil
    }
}

/// A menu that contains menu items.
@MainActor
public class UIMenu: Identifiable {
    /// The native menu surface where the menu is presented.
    public enum Placement: Equatable, Sendable {
        /// Present the menu as a regular top-level menu.
        case automatic
        /// Merge the menu's items into the platform application menu when available.
        case application
    }

    /// The menu’s identifier.
    public let id: String
    /// The menu’s title.
    public let title: String
    /// The native menu surface where the menu is presented.
    public let placement: Placement

    /// The menu builder that owns the menu.
    public private(set) weak var menuBuilder: UIMenuBuilder?

    /// The parent menu.
    public private(set) weak var parent: UIMenu?

    /// The menu items.
    public private(set) var items: [MenuItem] = []

    /// Initialize a new menu.
    ///
    /// - Parameters:
    ///   - title: The menu’s title.
    ///   - placement: The native menu surface where the menu is presented.
    public init(title: String, placement: Placement = .automatic) {
        self.id = title
        self.title = title
        self.placement = placement
    }

    /// Add a new menu item.
    ///
    /// - Parameter item: The menu item to add.
    public func add(_ item: MenuItem) {
        self.items.append(item)
        item.setMenuOwner(self)
    }

    /// Remove a menu item.
    ///
    /// - Parameter item: The menu item to remove.
    public func remove(_ item: MenuItem) {
        self.items.removeAll(where: { $0.id == item.id })
    }

    /// Set the menu builder that owns the menu.
    ///
    /// - Parameter owner: The menu builder to set.
    public func setMenuOwner(_ owner: UIMenuBuilder) {
        self.menuBuilder = owner
    }

    /// Update the menu.
    func update() {
    }
}
