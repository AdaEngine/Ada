//
//  ContextMenuPlugin.swift
//  AdaEngine
//
//  Created by Codex on 29.04.2026.
//

import AdaApp
import AdaECS
import AdaInput
import AdaRender
import AdaScene
@_spi(Internal) import AdaUI
import AdaUtils
import Math
import Observation

public struct ContextMenuPlugin: Plugin {
    public init() {}

    public func setup(in app: AppWorlds) {
        ContextMenuPresentationCenter.present = { presentation in
            ContextMenuPresenter.present(presentation, in: app)
        }
        ContextMenuPresentationCenter.dismissAll = {
            ContextMenuPresenter.dismissAll()
        }
        ContextMenuPresentationCenter.dismissForInteraction = { window in
            ContextMenuPresenter.dismissForInteraction(in: window)
        }
        ContextMenuPresentationCenter.dismissForDeactivation = { window in
            ContextMenuPresenter.dismissForDeactivation(of: window)
        }
        #if !os(iOS) && !os(visionOS)
            ContextMenuPresentationCenter.handleSelectionKey = { event, window in
                ContextMenuPresenter.handleSelectionKey(event, in: window)
            }
        #endif
    }
}

@MainActor
private enum ContextMenuPresenter {
    private static var activeSession: ContextMenuSession?

    static func present(_ presentation: ContextMenuPresentation, in app: AppWorlds) {
        guard !presentation.items.isEmpty else {
            return
        }

        #if os(iOS) || os(visionOS)
            IOSContextMenuPresentationCenter.present(presentation)
        #else
            activeSession?.closeAll()

            let session = ContextMenuSession(
                sourceWindow: presentation.sourceWindow,
                onDismiss: presentation.onDismiss,
                selection: presentation.isSelectionMenu ? ContextMenuSelection(items: presentation.items) : nil
            )
            activeSession = session
            let window = makeWindow(
                items: presentation.items,
                origin: menuOrigin(for: presentation, menuSize: menuSize(for: presentation.items, limitsHeight: session.selection != nil)),
                app: app,
                session: session,
                level: 0
            )
            session.setWindow(window, items: presentation.items, at: 0)
            window.showWindow(makeFocused: false)
        #endif
    }

    @discardableResult
    static func dismissAll() -> Bool {
        #if os(iOS) || os(visionOS)
            return IOSContextMenuPresentationCenter.dismissAll()
        #else
            guard let session = activeSession else {
                return false
            }

            session.closeAll()
            activeSession = nil
            return true
        #endif
    }

    static func dismissForInteraction(in window: UIWindow?) {
        #if os(iOS) || os(visionOS)
            IOSContextMenuPresentationCenter.dismissForInteraction(in: window)
        #else
            guard let activeSession, let window, !activeSession.contains(window) else {
                return
            }

            activeSession.closeAll()
            self.activeSession = nil
        #endif
    }

    static func dismissForDeactivation(of window: UIWindow?) {
        #if os(iOS) || os(visionOS)
            IOSContextMenuPresentationCenter.dismissForDeactivation(of: window)
        #else
            guard let activeSession, let window, activeSession.sourceWindow === window else {
                return
            }

            activeSession.closeAll()
            self.activeSession = nil
        #endif
    }

    static func presentSubmenu(
        items: [ContextMenuPresentation.Item],
        from parentWindow: UIWindow,
        parentLevel: Int,
        rowIndex: Int,
        in session: ContextMenuSession
    ) {
        guard !items.isEmpty else {
            return
        }

        session.closeSubmenus(from: parentLevel + 1)
        let level = parentLevel + 1
        let size = menuSize(for: items)
        let origin = submenuOrigin(
            parentWindow: parentWindow,
            parentItems: session.items(at: parentLevel),
            rowIndex: rowIndex,
            menuSize: size,
            sourceWindow: session.sourceWindow
        )
        let window = makeWindow(
            items: items,
            origin: origin,
            app: session.app,
            session: session,
            level: level
        )
        session.setWindow(window, items: items, at: level)
        window.showWindow(makeFocused: false)
    }

    static func closeSubmenus(from level: Int, in session: ContextMenuSession) {
        session.closeSubmenus(from: level)
    }

    static func performAction(_ action: (() -> Void)?, in session: ContextMenuSession) {
        session.closeAll()
        if activeSession === session {
            activeSession = nil
        }
        action?()
    }

    static func handleSelectionKey(_ event: KeyEvent, in window: UIWindow?) -> Bool {
        guard event.status == .down, let session = activeSession, let selection = session.selection,
              let window, session.sourceWindow === window || session.contains(window) else { return false }
        if event.keyCode == .tab {
            dismissAll()
            return false
        }
        guard event.modifiers.subtracting(.capsLock).isEmpty else { return false }
        switch selection.handle(event.keyCode) {
        case .moved: return true
        case let .confirmed(index):
            let items = session.items(at: 0)
            if !event.isRepeated, items.indices.contains(index) { performAction(items[index].action, in: session) }
            return true
        case .ignored: return false
        }
    }

    private static func makeWindow(
        items: [ContextMenuPresentation.Item],
        origin: Point,
        app: AppWorlds,
        session: ContextMenuSession,
        level: Int
    ) -> UIWindow {
        let size = menuSize(for: items, limitsHeight: session.selection != nil)
        let window = UIWindow(
            configuration: UIWindow.Configuration(
                title: "",
                frame: Rect(origin: origin, size: size),
                minimumSize: size,
                chrome: .borderless,
                background: .transparent,
                level: .floating,
                collectionBehavior: .allSpacesStationary,
                makeKey: false
            )
        )

        session.app = app
        let container = UIContainerView(
            rootView: ContextMenuWindowContent(
                items: items,
                window: window,
                session: session,
                level: level
            )
        )
        container.backgroundColor = Color.clear
        container.autoresizingRules = UIView.AutoresizingRule([.flexibleWidth, .flexibleHeight])
        container.frame = Rect(origin: .zero, size: size)
        window.addSubview(container)
        container.layoutSubviews()

        var camera = Camera(window: .windowId(window.id))
        camera.backgroundColor = Color(red: 0, green: 0, blue: 0, alpha: 0)
        window.runtimeCameraEntity = app.spawn(bundle: Camera2D(camera: camera))
        if let cameraEntity = window.runtimeCameraEntity { cameraEntity.components += WindowRenderOnDemand() }
        return window
    }

    private static func menuSize(for items: [ContextMenuPresentation.Item], limitsHeight: Bool = false) -> Size {
        let longestTitleCount = items.lazy.filter { !$0.isSeparator }.map(\.title.count).max() ?? 0
        let width = ContextMenuMetrics.width(longestTitleCharacterCount: longestTitleCount)
        let height = items.reduce(ContextMenuMetrics.verticalPadding * 2) { height, item in
            height + ContextMenuMetrics.height(for: item)
        }
        return Size(width: width, height: limitsHeight ? min(height, ContextMenuMetrics.selectionMaximumHeight) : height)
    }

    private static func menuOrigin(for presentation: ContextMenuPresentation, menuSize: Size) -> Point {
        guard
            let sourceWindow = presentation.sourceWindow,
            let systemWindow = sourceWindow.systemWindow
        else {
            return presentation.location
        }

        let sourceOrigin = systemWindow.contentPosition
        let sourceSize = sourceWindow.frame.size
        var origin = Point(
            x: sourceOrigin.x + presentation.location.x,
            y: sourceOrigin.y + sourceSize.height - presentation.location.y - menuSize.height
        )
        #if os(Windows)
            // Win32 desktop coordinates, like pointer coordinates, start at the top.
            origin.y = sourceOrigin.y + presentation.location.y
        #endif

        if let screenSize = sourceWindow.screen?.size {
            origin.x = min(max(0, origin.x), max(0, screenSize.width - menuSize.width))
            origin.y = min(max(0, origin.y), max(0, screenSize.height - menuSize.height))
        }

        return origin
    }

    private static func submenuOrigin(
        parentWindow: UIWindow,
        parentItems: [ContextMenuPresentation.Item],
        rowIndex: Int,
        menuSize: Size,
        sourceWindow: UIWindow?
    ) -> Point {
        guard let systemWindow = parentWindow.systemWindow else {
            return .zero
        }

        let parentOrigin = systemWindow.position
        let parentSize = parentWindow.frame.size
        var origin = Point(
            x: parentOrigin.x + parentSize.width - ContextMenuMetrics.submenuOverlap,
            y: parentOrigin.y + parentSize.height - ContextMenuMetrics.verticalPadding - rowOffset(for: rowIndex, in: parentItems) - menuSize.height
        )
        #if os(Windows)
            origin.y = parentOrigin.y + ContextMenuMetrics.verticalPadding + rowOffset(for: rowIndex, in: parentItems)
        #endif

        if let screenSize = (sourceWindow ?? parentWindow).screen?.size {
            if origin.x + menuSize.width > screenSize.width {
                origin.x = parentOrigin.x - menuSize.width + ContextMenuMetrics.submenuOverlap
            }
            origin.x = min(max(0, origin.x), max(0, screenSize.width - menuSize.width))
            origin.y = min(max(0, origin.y), max(0, screenSize.height - menuSize.height))
        }

        return origin
    }

    private static func rowOffset(for rowIndex: Int, in items: [ContextMenuPresentation.Item]) -> Float {
        items.prefix(rowIndex)
            .reduce(0) { offset, item in
                offset + ContextMenuMetrics.height(for: item)
            }
    }
}

@MainActor
private final class ContextMenuSession {
    weak var sourceWindow: UIWindow?
    var app: AppWorlds!
    let selection: ContextMenuSelection?
    private var onDismiss: (() -> Void)?
    private var windowsByLevel: [Int: UIWindow] = [:]
    private var itemsByLevel: [Int: [ContextMenuPresentation.Item]] = [:]

    init(sourceWindow: UIWindow?, onDismiss: (() -> Void)?, selection: ContextMenuSelection?) {
        self.sourceWindow = sourceWindow
        self.onDismiss = onDismiss
        self.selection = selection
    }

    func setWindow(_ window: UIWindow, items: [ContextMenuPresentation.Item], at level: Int) {
        windowsByLevel[level] = window
        itemsByLevel[level] = items
    }

    func items(at level: Int) -> [ContextMenuPresentation.Item] {
        itemsByLevel[level] ?? []
    }

    func contains(_ window: UIWindow) -> Bool {
        windowsByLevel.values.contains { $0 === window }
    }

    func closeSubmenus(from level: Int) {
        for closeLevel in windowsByLevel.keys.filter({ $0 >= level }).sorted(by: >) {
            windowsByLevel.removeValue(forKey: closeLevel)?.close()
            itemsByLevel.removeValue(forKey: closeLevel)
        }
    }

    func closeAll() {
        closeSubmenus(from: 0)
        onDismiss?()
        onDismiss = nil
    }
}

@MainActor @Observable
final class ContextMenuSelection {
    enum KeyResult: Equatable {
        case moved
        case confirmed(Int)
        case ignored
    }

    private let lastIndex: Int
    private(set) var index: Int

    init(items: [ContextMenuPresentation.Item]) {
        lastIndex = max(0, items.count - 1)
        index = items.firstIndex(where: \.isSelected) ?? 0
    }

    func handle(_ key: KeyCode) -> KeyResult {
        switch key {
        case .arrowDown: index = min(index + 1, lastIndex)
        case .arrowUp: index = max(index - 1, 0)
        case .enter, .space: return .confirmed(index)
        default: return .ignored
        }
        return .moved
    }
}

enum ContextMenuMetrics {
    static let rowHeight: Float = 28
    static let separatorHeight: Float = 9
    static let verticalPadding: Float = 5
    static let submenuOverlap: Float = 4
    static let minimumWidth: Float = 184
    static let maximumWidth: Float = 320
    static let horizontalPadding: Float = 10
    static let itemSpacing: Float = 8
    static let submenuIndicatorWidth: Float = 8
    static let selectionVisibleRows = 8
    static let selectionMaximumHeight = rowHeight * Float(selectionVisibleRows) + verticalPadding * 2

    static func width(longestTitleCharacterCount: Int) -> Float {
        max(minimumWidth, min(maximumWidth, Float(longestTitleCharacterCount * 7 + 44)))
    }

    static func titleWidth(menuWidth: Float, hasSubmenu: Bool, hasSelection: Bool = false) -> Float {
        let submenuWidth = hasSubmenu ? itemSpacing + submenuIndicatorWidth : 0
        let selectionWidth: Float = hasSelection ? 12 + itemSpacing : 0
        return max(0, menuWidth - horizontalPadding * 2 - submenuWidth - selectionWidth)
    }

    static func height(for item: ContextMenuPresentation.Item) -> Float {
        item.isSeparator ? separatorHeight : rowHeight
    }
}

private struct ContextMenuWindowContent: View {
    let items: [ContextMenuPresentation.Item]
    weak var window: UIWindow?
    let session: ContextMenuSession
    let level: Int

    var body: some View {
        Group {
            if let selection = session.selection, items.count > ContextMenuMetrics.selectionVisibleRows {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) { menuRows }
                        .frame(height: ContextMenuMetrics.selectionMaximumHeight)
                        .onAppear { proxy.scrollTo(selection.index, anchor: .center) }
                        .onChange(of: selection.index) { _, index in proxy.scrollTo(index, anchor: .center) }
                }
            } else {
                menuRows
            }
        }
        .frame(width: menuWidth)
        .background(RoundedRectangleShape(cornerRadius: 7).fill(backgroundColor))
        .overlay {
            RoundedRectangleShape(cornerRadius: 7)
                .stroke(borderColor, lineWidth: 1)
        }
    }

    private var menuRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<items.count) { index in
                menuRow(for: items[index], at: index)
                    .id(index)
            }
        }
        .padding(.vertical, ContextMenuMetrics.verticalPadding)
    }

    @ViewBuilder
    private func menuRow(for item: ContextMenuPresentation.Item, at index: Int) -> some View {
        if item.isSeparator {
            RectangleShape()
                .fill(borderColor)
                .frame(width: menuWidth - 16, height: 1)
                .padding(.horizontal, 8)
                .frame(width: menuWidth, height: ContextMenuMetrics.separatorHeight)
        } else {
            Button(action: {
                if item.submenu.isEmpty {
                    ContextMenuPresenter.performAction(item.action, in: session)
                } else if let window {
                    ContextMenuPresenter.presentSubmenu(
                        items: item.submenu,
                        from: window,
                        parentLevel: level,
                        rowIndex: index,
                        in: session
                    )
                }
            }, label: {
                HStack(spacing: ContextMenuMetrics.itemSpacing) {
                    if items.contains(where: \.isSelected) {
                        ContextMenuCheckmark()
                            .stroke(primaryTextColor, lineWidth: 1.8)
                            .frame(width: 12, height: 12)
                            .opacity(item.isSelected ? 1 : 0)
                            .accessibilityIdentifier("AdaUI.ContextMenu.Checkmark.\(item.id)")
                    }
                    Text(item.title)
                        .font(.system(size: 12))
                        .foregroundColor(item.role == .destructive ? destructiveTextColor : primaryTextColor)
                        .lineLimit(1)
                        .frame(
                            width: ContextMenuMetrics.titleWidth(menuWidth: menuWidth, hasSubmenu: !item.submenu.isEmpty, hasSelection: items.contains(where: \.isSelected)),
                            height: ContextMenuMetrics.rowHeight,
                            alignment: .leading
                        )
                    if !item.submenu.isEmpty {
                        Text(">")
                            .font(.system(size: 12))
                            .foregroundColor(primaryTextColor.opacity(0.74))
                            .frame(width: ContextMenuMetrics.submenuIndicatorWidth, height: ContextMenuMetrics.rowHeight)
                    }
                }
                .padding(.horizontal, ContextMenuMetrics.horizontalPadding)
                .frame(width: menuWidth, height: ContextMenuMetrics.rowHeight)
            })
            .buttonStyle(ContextMenuButtonStyle(role: item.role, keyboardHighlighted: session.selection?.index == index))
            .onHover { isHovered in
                guard isHovered else {
                    return
                }

                if item.submenu.isEmpty {
                    ContextMenuPresenter.closeSubmenus(from: level + 1, in: session)
                } else if let window {
                    ContextMenuPresenter.presentSubmenu(
                        items: item.submenu,
                        from: window,
                        parentLevel: level,
                        rowIndex: index,
                        in: session
                    )
                }
            }
        }
    }

    private var menuWidth: Float {
        ContextMenuMetrics.width(
            longestTitleCharacterCount: items.lazy.filter { !$0.isSeparator }.map(\.title.count).max() ?? 0
        )
    }
}

struct ContextMenuCheckmark: Shape {
    typealias AnimatableData = EmptyAnimatableData

    func path(in rect: Rect) -> Path {
        Path { path in
            path.move(to: Point(rect.minX + rect.width * 0.1, rect.minY + rect.height * 0.5))
            path.addLine(to: Point(rect.minX + rect.width * 0.4, rect.minY + rect.height * 0.8))
            path.addLine(to: Point(rect.minX + rect.width * 0.9, rect.minY + rect.height * 0.2))
        }
    }
}

private struct ContextMenuButtonStyle: ButtonStyle {
    let role: ContextMenuPresentation.Item.Role?
    let keyboardHighlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangleShape(cornerRadius: 5)
                    .fill(
                        configuration.isHighlighted || keyboardHighlighted ? highlightColor : Color.clear
                    )
            )
    }
}

private let backgroundColor = Color(red: 24 / 255, green: 25 / 255, blue: 29 / 255, alpha: 1)
private let borderColor = Color(red: 66 / 255, green: 70 / 255, blue: 78 / 255, alpha: 1)
private let highlightColor = Color(red: 39 / 255, green: 41 / 255, blue: 46 / 255, alpha: 1)
private let primaryTextColor = Color(red: 223 / 255, green: 225 / 255, blue: 229 / 255, alpha: 1)
private let destructiveTextColor = Color(red: 1.0, green: 0.36, blue: 0.36, alpha: 1)
