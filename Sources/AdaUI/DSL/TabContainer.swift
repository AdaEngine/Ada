//
//  TabContainer.swift
//  AdaEngine
//
//  Created by Codex on 24.03.2026.
//

import AdaAnimation
import AdaInput
import AdaRender
import AdaText
import AdaUtils
import Math

// MARK: - TabViewPosition

/// The position of the tab bar relative to the content.
public enum TabViewPosition: Sendable {
    case top
    case bottom
    case left
    case right
}

// MARK: - TabLabelStyle

/// Controls which parts of a tab label are displayed.
public enum TabLabelStyle: Sendable {
    /// Show only the image.
    case compact
    /// Show both image and text.
    case regular
}

// MARK: - TabViewStyleConfiguration

/// The properties of a tab view style.
public struct TabViewStyleConfiguration {
    /// A single tab item exposed to the style.
    public struct Tab: Identifiable {
        /// The value that uniquely identifies this tab (matches the `Tab` view's `value`).
        public let id: AnyHashable
        /// The text label of the tab, if any.
        public let label: String?
        /// The image of the tab, if any.
        public let image: Image?
        /// Whether this tab is currently selected.
        public let isSelected: Bool
        /// Call to select this tab.
        public let action: () -> Void
    }

    /// A view that displays the content of the currently selected tab.
    /// Place this in your custom style body to control where tab content appears.
    public struct Content: View, ViewNodeBuilder {
        public typealias Body = Never
        public var body: Never { fatalError("Unreachable code") }

        let proxy: TabContentProxyNode

        func buildViewNode(in _: BuildContext) -> ViewNode {
            proxy
        }
    }

    /// All tabs in the tab bar (excludes structural elements like spacers and section headers).
    public let tabs: [Tab]
    /// The position of the tab bar.
    public let position: TabViewPosition
    /// The content of the currently selected tab.
    public let content: Content
}

// MARK: - TabViewStyle

/// A protocol that defines a tab view style, allowing full customisation of the tab bar.
@_typeEraser(AnyTabViewStyle)
@MainActor public protocol TabViewStyle: Sendable {
    /// The body produced by this style.
    associatedtype Body: View
    /// The configuration type passed to `makeBody`.
    typealias Configuration = TabViewStyleConfiguration
    /// Build the view that represents the tab bar.
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

// MARK: - DefaultTabViewStyle

/// The built-in tab bar appearance used when no custom style is applied.
public struct DefaultTabViewStyle: TabViewStyle {
    public init() {}

    /// Not called at runtime — `TabViewNode` special-cases `DefaultTabViewStyle`
    /// and uses its own imperative tab bar builder instead.
    public func makeBody(configuration _: Configuration) -> some View {
        EmptyView()
    }
}

// MARK: - AnyTabViewStyle

/// A type-erased tab view style.
public struct AnyTabViewStyle: TabViewStyle {
    let style: any TabViewStyle

    public init<S: TabViewStyle>(erasing style: S) {
        self.style = style
    }

    public func makeBody(configuration: Configuration) -> AnyView {
        AnyView(style.makeBody(configuration: configuration))
    }
}

// MARK: - TabBarElement

enum TabBarElement {
    case tab(
        label: String?,
        image: Image?,
        value: AnyHashable,
        makeContent: @MainActor (_ViewInputs) -> ViewNode
    )
    case sectionHeader(String)
    case spacer
    case divider
}

// MARK: - _TabItem

@MainActor
protocol _TabItem {
    func _extractTabBarElements(inputs: _ViewInputs) -> [TabBarElement]
}

// MARK: - Tab

/// A single tab item with a label, optional image, and associated content.
@MainActor @preconcurrency
public struct Tab<Value: Hashable, Content: View>: View, ViewNodeBuilder {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    let label: String?
    let image: Image?
    let value: Value
    let content: () -> Content

    /// Creates a tab with a text label, optional image, and content.
    public init(
        _ label: String,
        image: Image? = nil,
        value: Value,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.image = image
        self.value = value
        self.content = content
    }

    /// Creates a tab with only an image and content.
    public init(
        image: Image,
        value: Value,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = nil
        self.image = image
        self.value = value
        self.content = content
    }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        Content._makeView(_ViewGraphNode(value: content()), inputs: context).node
    }
}

extension Tab: _TabItem {
    func _extractTabBarElements(inputs: _ViewInputs) -> [TabBarElement] {
        let label = self.label
        let image = self.image
        let hashableValue = AnyHashable(value)
        let contentClosure = content
        let makeContent: @MainActor (_ViewInputs) -> ViewNode = { inputs in
            Content._makeView(_ViewGraphNode(value: contentClosure()), inputs: inputs).node
        }
        return [.tab(label: label, image: image, value: hashableValue, makeContent: makeContent)]
    }
}

// MARK: - TabSection

/// A labeled group of tabs in a TabView.
@MainActor @preconcurrency
public struct TabSection<Content: View>: View, ViewNodeBuilder {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    let title: String
    let content: () -> Content

    public init(
        _ title: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.content = content
    }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        Content._makeView(_ViewGraphNode(value: content()), inputs: context).node
    }
}

extension TabSection: _TabItem {
    func _extractTabBarElements(inputs: _ViewInputs) -> [TabBarElement] {
        var elements: [TabBarElement] = [.sectionHeader(title)]
        elements += extractTabBarElements(from: content(), inputs: inputs)
        return elements
    }
}

// MARK: - Spacer + Divider as tab bar items

extension Spacer: _TabItem {
    @MainActor func _extractTabBarElements(inputs _: _ViewInputs) -> [TabBarElement] {
        [.spacer]
    }
}

extension Divider: _TabItem {
    @MainActor func _extractTabBarElements(inputs _: _ViewInputs) -> [TabBarElement] {
        [.divider]
    }
}

// MARK: - TabView

/// A view that switches between multiple child views using a tab bar.
@MainActor @preconcurrency
public struct TabView<Selection: Hashable, Content: View>: View, ViewNodeBuilder {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    let selection: Binding<Selection>
    let content: () -> Content

    public init(
        selection: Binding<Selection>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.selection = selection
        self.content = content
    }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let contentView = content()
        let elements = extractTabBarElements(from: contentView, inputs: context)
        return TabViewNode(inputs: context, tabView: self, elements: elements)
    }
}

// MARK: - EnvironmentValues

extension EnvironmentValues {
    var tabViewPosition: TabViewPosition {
        get { self[TabViewPositionKey.self] }
        set { self[TabViewPositionKey.self] = newValue }
    }

    var tabLabelStyle: TabLabelStyle {
        get { self[TabLabelStyleKey.self] }
        set { self[TabLabelStyleKey.self] = newValue }
    }

    var tabViewStyle: any TabViewStyle {
        get { self[TabViewStyleKey.self] }
        set { self[TabViewStyleKey.self] = newValue }
    }

    private struct TabViewPositionKey: EnvironmentKey {
        static let defaultValue: TabViewPosition = .top
    }

    private struct TabLabelStyleKey: EnvironmentKey {
        static let defaultValue: TabLabelStyle = .regular
    }

    private struct TabViewStyleKey: @preconcurrency EnvironmentKey {
        @MainActor static let defaultValue: any TabViewStyle = DefaultTabViewStyle()
    }
}

extension View {
    /// Sets the position of the tab bar in a TabView.
    public func tabViewPosition(_ position: TabViewPosition) -> some View {
        self.environment(\.tabViewPosition, position)
    }

    /// Sets the label style for tabs in a TabView.
    public func tabLabelStyle(_ style: TabLabelStyle) -> some View {
        self.environment(\.tabLabelStyle, style)
    }

    /// Sets the style for tab views within this view.
    public func tabViewStyle<S: TabViewStyle>(_ style: S) -> some View {
        self.environment(\.tabViewStyle, style)
    }
}

// MARK: - Tab bar element extraction

@MainActor
private func extractTabBarElements<V: View>(from view: V, inputs: _ViewInputs) -> [TabBarElement] {
    if let item = view as? any _TabItem {
        return item._extractTabBarElements(inputs: inputs)
    }

    let mirror = Mirror(reflecting: view)
    var result: [TabBarElement] = []

    for (_, child) in mirror.children {
        if let childView = child as? any View {
            result += extractTabBarElements(from: childView, inputs: inputs)
        } else {
            let childMirror = Mirror(reflecting: child)
            for (_, grandchild) in childMirror.children {
                if let grandchildView = grandchild as? any View {
                    result += extractTabBarElements(from: grandchildView, inputs: inputs)
                }
            }
        }
    }

    return result
}

// MARK: - Constants

private enum TabViewConstants {
    static var tabBarHeight: Float { 48 }
    static var tabBarWidth: Float { 200 }
    static var tabBarBorderWidth: Float { 1 }
    static var tabHorizontalPadding: Float { 16 }
    static var iconSize: Float { 18 }
    static var iconTextGap: Float { 4 }
    static var selectedIndicatorThickness: Float { 3 }
    static var sectionHeaderFontSize: Float { 11 }
    static var sectionHeaderHeight: Float { 28 }

    static var tabTextColor: Color { .fromHex(0x666666) }
    static var selectedTabTextColor: Color { .fromHex(0xF0F0F0) }
    static var indicatorColor: Color { .fromHex(0xFF2D6F) }
    static var borderColor: Color { .fromHex(0x2A2A2A) }
    static var sectionHeaderColor: Color { .fromHex(0x555555) }
    static var highlightColor: Color { .fromHex(0x1A1A1A) }
    static var tapMovementThreshold: Float { 10 }
}

// MARK: - TabContentProxyNode

/// A node that transparently delegates all rendering and event handling to a
/// mutable target node. Used by custom `TabViewStyle` implementations to embed
/// the currently-selected tab content anywhere in their view hierarchy.
final class TabContentProxyNode: ViewNode {
    init() {
        super.init(content: EmptyView())
    }

    var target: ViewNode? {
        didSet {
            oldValue?.parent = nil
            if let target {
                target.parent = self
                if let owner {
                    target.updateViewOwner(owner)
                }
            }
            performLayout()
            invalidateNearestLayer()
            owner?.containerView?.setNeedsDisplay(in: absoluteFrame())
        }
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        target?.sizeThatFits(proposal) ?? proposal.replacingUnspecifiedDimensions()
    }

    override func performLayout() {
        guard let target else {
            return
        }
        target.place(
            in: Point(x: frame.width * 0.5, y: frame.height * 0.5),
            anchor: .center,
            proposal: ProposedViewSize(width: frame.width, height: frame.height)
        )
    }

    override func draw(with context: UIGraphicsContext) {
        var ctx = context
        ctx.environment = environment
        ctx.translateBy(x: frame.origin.x, y: -frame.origin.y)
        target?.draw(with: ctx)
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event), let target else {
            return nil
        }
        let targetPoint = target.convert(point, from: self)
        return target.hitTest(targetPoint, with: event)
    }

    override func update(_ deltaTime: TimeInterval) {
        target?.update(deltaTime)
    }

    override func updateViewOwner(_ owner: ViewOwner) {
        super.updateViewOwner(owner)
        target?.updateViewOwner(owner)
    }

    override func updateEnvironment(_ environment: EnvironmentValues) {
        super.updateEnvironment(environment)
        target?.updateEnvironment(environment)
    }

    override func findNodeById(_ id: AnyHashable) -> ViewNode? {
        target?.findNodeById(id)
    }

    override func findNodyByAccessibilityIdentifier(_ identifier: String) -> ViewNode? {
        target?.findNodyByAccessibilityIdentifier(identifier)
    }
}

// MARK: - TabViewNode

final class TabViewNode<Selection: Hashable, Content: View>: ViewNode {
    private var elements: [TabBarElement]
    private var selectionBinding: Binding<Selection>
    private var position: TabViewPosition
    private var viewInputs: _ViewInputs

    private var tabBarNode: ViewNode
    private var contentNode: ViewNode
    private var cachedContentNodes: [AnyHashable: ViewNode] = [:]
    private var tabViewStyleTypeName: String
    private let contentProxy = TabContentProxyNode()

    private var tabBarHeight: Float { TabViewConstants.tabBarHeight }
    private var tabBarWidth: Float { TabViewConstants.tabBarWidth }
    private var isHorizontalBar: Bool { position == .top || position == .bottom }
    private var isCustomStyle: Bool { !(environment.tabViewStyle is DefaultTabViewStyle) }

    init(inputs: _ViewInputs, tabView: TabView<Selection, Content>, elements: [TabBarElement]) {
        self.elements = elements
        self.selectionBinding = tabView.selection
        self.position = inputs.environment.tabViewPosition
        self.viewInputs = inputs

        let selected = AnyHashable(tabView.selection.wrappedValue)
        let isCustom = !(inputs.environment.tabViewStyle is DefaultTabViewStyle)

        self.tabViewStyleTypeName = String(describing: type(of: inputs.environment.tabViewStyle))
        self.tabBarNode = Self.buildStyledTabBar(
            elements: elements,
            selected: selected,
            position: inputs.environment.tabViewPosition,
            inputs: inputs,
            contentProxy: contentProxy,
            onSelect: { _ in }
        )
        self.contentNode = Self.buildContent(
            for: selected,
            from: elements,
            inputs: inputs
        )

        super.init(content: tabView)

        self.cachedContentNodes[selected] = self.contentNode
        self.tabBarNode.parent = self
        if isCustom {
            contentProxy.parent = self
            contentProxy.target = self.contentNode
        } else {
            self.contentNode.parent = self
        }

        let weakSelf = WeakBox(self)
        self.tabBarNode = Self.buildStyledTabBar(
            elements: elements,
            selected: selected,
            position: inputs.environment.tabViewPosition,
            inputs: inputs,
            contentProxy: contentProxy,
            onSelect: { value in
                weakSelf.value?.selectTab(value)
            }
        )
        self.tabBarNode.parent = self
    }

    override var canBecomeFocused: Bool { false }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        let width = proposal.width ?? 300
        let height = proposal.height ?? 300

        guard environment.tabViewStyle is DefaultTabViewStyle else {
            // Custom style: tab bar overlays content, total size equals content size.
            return Size(width: width, height: height)
        }

        if isHorizontalBar {
            let contentHeight = proposal.height.map { max(0, $0 - tabBarHeight) }
            return Size(
                width: width,
                height: tabBarHeight + (contentHeight ?? height)
            )
        } else {
            let contentWidth = proposal.width.map { max(0, $0 - tabBarWidth) }
            return Size(
                width: tabBarWidth + (contentWidth ?? width),
                height: height
            )
        }
    }

    override func performLayout() {
        guard environment.tabViewStyle is DefaultTabViewStyle else {
            performOverlayLayout()
            return
        }
        performDefaultLayout()
    }

    /// Side-by-side layout used by DefaultTabViewStyle.
    private func performDefaultLayout() {
        switch position {
        case .top:
            tabBarNode.place(
                in: Point(x: frame.width * 0.5, y: tabBarHeight * 0.5),
                anchor: .center,
                proposal: ProposedViewSize(width: frame.width, height: tabBarHeight)
            )
            let contentHeight = max(0, frame.height - tabBarHeight)
            contentNode.place(
                in: Point(x: frame.width * 0.5, y: tabBarHeight + contentHeight * 0.5),
                anchor: .center,
                proposal: ProposedViewSize(width: frame.width, height: contentHeight)
            )

        case .bottom:
            let contentHeight = max(0, frame.height - tabBarHeight)
            contentNode.place(
                in: Point(x: frame.width * 0.5, y: contentHeight * 0.5),
                anchor: .center,
                proposal: ProposedViewSize(width: frame.width, height: contentHeight)
            )
            tabBarNode.place(
                in: Point(x: frame.width * 0.5, y: contentHeight + tabBarHeight * 0.5),
                anchor: .center,
                proposal: ProposedViewSize(width: frame.width, height: tabBarHeight)
            )

        case .left:
            tabBarNode.place(
                in: Point(x: tabBarWidth * 0.5, y: frame.height * 0.5),
                anchor: .center,
                proposal: ProposedViewSize(width: tabBarWidth, height: frame.height)
            )
            let contentWidth = max(0, frame.width - tabBarWidth)
            contentNode.place(
                in: Point(x: tabBarWidth + contentWidth * 0.5, y: frame.height * 0.5),
                anchor: .center,
                proposal: ProposedViewSize(width: contentWidth, height: frame.height)
            )

        case .right:
            let contentWidth = max(0, frame.width - tabBarWidth)
            contentNode.place(
                in: Point(x: contentWidth * 0.5, y: frame.height * 0.5),
                anchor: .center,
                proposal: ProposedViewSize(width: contentWidth, height: frame.height)
            )
            tabBarNode.place(
                in: Point(x: contentWidth + tabBarWidth * 0.5, y: frame.height * 0.5),
                anchor: .center,
                proposal: ProposedViewSize(width: tabBarWidth, height: frame.height)
            )
        }
    }

    /// Layout for custom styles: the style body (tabBarNode) fills the full frame.
    /// The style is responsible for laying out both the tab bar UI and the content
    /// (via `configuration.content`).
    private func performOverlayLayout() {
        tabBarNode.place(
            in: Point(x: frame.width * 0.5, y: frame.height * 0.5),
            anchor: .center,
            proposal: ProposedViewSize(width: frame.width, height: frame.height)
        )
    }

    override func update(from newNode: ViewNode) {
        guard let other = newNode as? TabViewNode<Selection, Content> else {
            return
        }
        let oldValues = Self.tabValues(from: elements)
        let newValues = Self.tabValues(from: other.elements)
        let elementsChanged = oldValues != newValues
        let positionChanged = self.position != other.position
        let newStyleTypeName = String(describing: type(of: other.viewInputs.environment.tabViewStyle))
        let styleChanged = self.tabViewStyleTypeName != newStyleTypeName

        for key in oldValues.subtracting(newValues) {
            cachedContentNodes[key]?.parent = nil
            cachedContentNodes.removeValue(forKey: key)
        }
        self.elements = other.elements
        self.selectionBinding = other.selectionBinding
        self.position = other.position
        self.viewInputs = other.viewInputs
        self.tabViewStyleTypeName = newStyleTypeName
        super.update(from: other)
        self.viewInputs.environment = self.environment

        // Propagate environment to children
        self.tabBarNode.updateEnvironment(self.environment)
        self.contentNode.updateEnvironment(self.environment)
        if isCustomStyle {
            self.contentProxy.updateEnvironment(self.environment)
        }

        if elementsChanged || positionChanged || styleChanged {
            rebuildAll()
        } else {
            updateSelectionOnly()
        }
    }

    override func invalidateContent() {
        rebuildAll()
    }

    override func updateEnvironment(_ environment: EnvironmentValues) {
        let prevVersion = self.environment.version
        super.updateEnvironment(environment)
        guard self.environment.version != prevVersion else {
            return
        }
        viewInputs.environment = self.environment

        tabBarNode.updateEnvironment(self.environment)

        // Zero the safe area edge the tab bar occupies so content children
        // don't add redundant inset for an edge the tab bar already covers.
        var contentEnv = self.environment
        switch position {
        case .top: contentEnv.safeAreaInsets.top = 0
        case .bottom: contentEnv.safeAreaInsets.bottom = 0
        case .left: contentEnv.safeAreaInsets.leading = 0
        case .right: contentEnv.safeAreaInsets.trailing = 0
        }
        // Keep offscreen cached tabs lazy: propagating environment through every cached
        // subtree on each layout/env tick makes tab switches scale with the total number
        // of visited tabs instead of only the visible one.
        for node in cachedContentNodes.values {
            node.updateEnvironment(contentEnv)
        }
    }

    override func updateViewOwner(_ owner: ViewOwner) {
        super.updateViewOwner(owner)
        tabBarNode.updateViewOwner(owner)
        if isCustomStyle {
            contentProxy.updateViewOwner(owner)
        }
        for cachedNode in cachedContentNodes.values {
            cachedNode.updateViewOwner(owner)
        }
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event) else {
            return nil
        }

        let tabBarPoint = tabBarNode.convert(point, from: self)
        if let hit = tabBarNode.hitTest(tabBarPoint, with: event) {
            return hit
        }

        // For custom styles, content is embedded in tabBarNode via the proxy.
        guard !isCustomStyle else {
            return nil
        }
        let contentPoint = contentNode.convert(point, from: self)
        return contentNode.hitTest(contentPoint, with: event)
    }

    override func draw(with context: UIGraphicsContext) {
        var ctx = context
        ctx.environment = environment
        ctx.translateBy(x: frame.origin.x, y: -frame.origin.y)

        if isCustomStyle {
            // Custom style owns the entire layout (content is embedded via the proxy).
            tabBarNode.draw(with: ctx)
        } else {
            tabBarNode.draw(with: ctx)
            drawSeparator(with: ctx)
            contentNode.draw(with: ctx)
        }
    }

    override func update(_ deltaTime: TimeInterval) {
        tabBarNode.update(deltaTime)
        // For custom styles, content is updated through the proxy inside tabBarNode.
        if !isCustomStyle {
            contentNode.update(deltaTime)
        }
    }

    override func findNodeById(_ id: AnyHashable) -> ViewNode? {
        tabBarNode.findNodeById(id) ?? contentNode.findNodeById(id)
    }

    override func findNodyByAccessibilityIdentifier(_ identifier: String) -> ViewNode? {
        if let result = super.findNodyByAccessibilityIdentifier(identifier) {
            return result
        }
        return tabBarNode.findNodyByAccessibilityIdentifier(identifier)
            ?? contentNode.findNodyByAccessibilityIdentifier(identifier)
    }

    // MARK: - Private

    private func drawSeparator(with context: UIGraphicsContext) {
        switch position {
        case .top:
            context.drawLine(
                start: Point(0, -tabBarHeight),
                end: Point(frame.width, -tabBarHeight),
                lineWidth: TabViewConstants.tabBarBorderWidth,
                color: TabViewConstants.borderColor
            )
        case .bottom:
            let contentHeight = max(0, frame.height - tabBarHeight)
            context.drawLine(
                start: Point(0, -contentHeight),
                end: Point(frame.width, -contentHeight),
                lineWidth: TabViewConstants.tabBarBorderWidth,
                color: TabViewConstants.borderColor
            )
        case .left:
            context.drawLine(
                start: Point(tabBarWidth, 0),
                end: Point(tabBarWidth, -frame.height),
                lineWidth: TabViewConstants.tabBarBorderWidth,
                color: TabViewConstants.borderColor
            )
        case .right:
            let contentWidth = max(0, frame.width - tabBarWidth)
            context.drawLine(
                start: Point(contentWidth, 0),
                end: Point(contentWidth, -frame.height),
                lineWidth: TabViewConstants.tabBarBorderWidth,
                color: TabViewConstants.borderColor
            )
        }
    }

    private func selectTab(_ value: AnyHashable) {
        guard
            let typedValue = value.base as? Selection,
            selectionBinding.wrappedValue != typedValue
        else {
            return
        }
        // Setting wrappedValue triggers StateStorage.update() → invalidateContent() on
        // the parent State owner → body re-evaluation → TabViewNode.update(from:) →
        // updateSelectionOnly(). The explicit rebuildAll() that used to follow was redundant.
        selectionBinding.wrappedValue = typedValue
    }

    /// Fast path: only selection changed, no structural change to elements.
    /// Updates tab bar button states and swaps the content node without rebuilding nodes.
    private func updateSelectionOnly() {
        let selected = AnyHashable(selectionBinding.wrappedValue)
        var contentEnv = environment
        switch position {
        case .top: contentEnv.safeAreaInsets.top = 0
        case .bottom: contentEnv.safeAreaInsets.bottom = 0
        case .left: contentEnv.safeAreaInsets.leading = 0
        case .right: contentEnv.safeAreaInsets.trailing = 0
        }

        if let defaultBarNode = tabBarNode as? LayoutViewContainerNode {
            // Default style: update selection state on existing tab bar buttons in-place (no rebuild)
            for node in defaultBarNode.nodes {
                guard let button = node as? TabItemButtonNode else {
                    continue
                }
                button.updateSelection(selected)
            }
        } else {
            // Custom style: update the existing tab bar node in-place to preserve @State
            // (e.g. indicator animation state). rebuildTabBar() would discard @State and
            // prevent onChange(of: selectedTabIndex) from firing correctly.
            let weakSelf = WeakBox(self)
            let newTabBarNode = Self.buildStyledTabBar(
                elements: elements,
                selected: selected,
                position: position,
                inputs: viewInputs,
                contentProxy: contentProxy,
                onSelect: { value in weakSelf.value?.selectTab(value) }
            )
            tabBarNode.update(from: newTabBarNode)
        }

        // Swap content node only if selection actually changed
        let wasAlreadyCached = cachedContentNodes[selected] != nil
        let newContentNode = getOrCreateContentNode(for: selected)
        if contentNode !== newContentNode {
            if !isCustomStyle {
                contentNode.parent = nil
            }
            contentNode = newContentNode
            if isCustomStyle {
                contentProxy.target = newContentNode
            } else {
                contentNode.parent = self
            }
        }

        // Offscreen cached tabs no longer receive environment updates eagerly, so the
        // newly selected tab must always be refreshed before it becomes visible.
        if let owner, !wasAlreadyCached || newContentNode.owner !== owner {
            newContentNode.updateViewOwner(owner)
        }
        newContentNode.updateEnvironment(contentEnv)

        self.invalidateNearestLayer()
        if let containerView = self.owner?.containerView {
            containerView.setNeedsDisplay(in: self.absoluteFrame())
        }
        self.performLayout()
    }

    private func rebuildTabBar(selected: AnyHashable, onSelect: @escaping (AnyHashable) -> Void) {
        tabBarNode.parent = nil
        tabBarNode = Self.buildStyledTabBar(
            elements: elements,
            selected: selected,
            position: position,
            inputs: viewInputs,
            contentProxy: contentProxy,
            onSelect: onSelect
        )
        tabBarNode.parent = self
        if let owner {
            tabBarNode.updateViewOwner(owner)
        }
        tabBarNode.updateEnvironment(environment)
    }

    private func rebuildAll() {
        let selected = AnyHashable(selectionBinding.wrappedValue)
        let weakSelf = WeakBox(self)

        rebuildTabBar(selected: selected, onSelect: { value in weakSelf.value?.selectTab(value) })

        let newContentNode = getOrCreateContentNode(for: selected)
        if contentNode !== newContentNode {
            if !isCustomStyle {
                contentNode.parent = nil
            }
            contentNode = newContentNode
            if isCustomStyle {
                contentProxy.target = newContentNode
            } else {
                contentNode.parent = self
            }
        }
        var contentEnv = environment
        switch position {
        case .top: contentEnv.safeAreaInsets.top = 0
        case .bottom: contentEnv.safeAreaInsets.bottom = 0
        case .left: contentEnv.safeAreaInsets.leading = 0
        case .right: contentEnv.safeAreaInsets.trailing = 0
        }
        if let owner {
            contentNode.updateViewOwner(owner)
        }
        contentNode.updateEnvironment(contentEnv)

        self.invalidateNearestLayer()
        if let containerView = self.owner?.containerView {
            containerView.setNeedsDisplay(in: self.absoluteFrame())
        }
        self.performLayout()
    }

    private func getOrCreateContentNode(for value: AnyHashable) -> ViewNode {
        for element in elements {
            if case let .tab(_, _, v, makeContent) = element, v == value {
                if let cached = cachedContentNodes[value] {
                    let newNode = makeContent(viewInputs)
                    cached.update(from: newNode)
                    cached.invalidateContent()
                    return cached
                }

                let node = makeContent(viewInputs)
                cachedContentNodes[value] = node
                return node
            }
        }
        return EmptyView._makeView(_ViewGraphNode(value: EmptyView()), inputs: viewInputs).node
    }

    private static func tabValues(from elements: [TabBarElement]) -> Set<AnyHashable> {
        Set(
            elements.compactMap { elem -> AnyHashable? in
                if case let .tab(_, _, v, _) = elem {
                    return v
                }
                return nil
            }
        )
    }

    /// Routes tab bar construction to either the built-in imperative path (DefaultTabViewStyle)
    /// or the style's `makeBody` for custom styles.
    private static func buildStyledTabBar(
        elements: [TabBarElement],
        selected: AnyHashable,
        position: TabViewPosition,
        inputs: _ViewInputs,
        contentProxy: TabContentProxyNode,
        onSelect: @escaping (AnyHashable) -> Void
    ) -> ViewNode {
        let style = inputs.environment.tabViewStyle
        guard !(style is DefaultTabViewStyle) else {
            return buildTabBar(elements: elements, selected: selected, position: position, inputs: inputs, onSelect: onSelect)
        }
        let tabs = elements.compactMap { element -> TabViewStyleConfiguration.Tab? in
            guard case let .tab(label, image, value, _) = element else {
                return nil
            }
            return TabViewStyleConfiguration.Tab(
                id: value,
                label: label,
                image: image,
                isSelected: value == selected,
                action: { onSelect(value) }
            )
        }
        let content = TabViewStyleConfiguration.Content(proxy: contentProxy)
        let configuration = TabViewStyleConfiguration(tabs: tabs, position: position, content: content)
        let body = AnyView(style.makeBody(configuration: configuration))
        return AnyView._makeView(_ViewGraphNode(value: body), inputs: inputs).node
    }

    private static func buildTabBar(
        elements: [TabBarElement],
        selected: AnyHashable,
        position: TabViewPosition,
        inputs: _ViewInputs,
        onSelect: @escaping (AnyHashable) -> Void
    ) -> LayoutViewContainerNode {
        let isHorizontal = position == .top || position == .bottom
        let nodes = buildTabBarNodes(
            elements: elements,
            selected: selected,
            isHorizontal: isHorizontal,
            inputs: inputs,
            onSelect: onSelect
        )
        let layout: any Layout =
            isHorizontal
            ? EqualWidthTabBarLayout()
            : VStackLayout(alignment: .leading, spacing: 0)
        return LayoutViewContainerNode(layout: layout, content: EmptyView(), nodes: nodes)
    }

    private static func buildTabBarNodes(
        elements: [TabBarElement],
        selected: AnyHashable,
        isHorizontal: Bool,
        inputs: _ViewInputs,
        onSelect: @escaping (AnyHashable) -> Void
    ) -> [ViewNode] {
        var nodes: [ViewNode] = []
        for element in elements {
            switch element {
            case let .tab(label, image, value, _):
                let button = TabItemButton(
                    label: label,
                    image: image,
                    value: value,
                    isSelected: value == selected,
                    isHorizontalBar: isHorizontal,
                    action: { onSelect(value) }
                )
                let node = TabItemButtonNode(content: button, inputs: inputs)
                nodes.append(node)
            case let .sectionHeader(title):
                guard !isHorizontal else {
                    continue
                }
                let header = TabSectionHeader(title: title)
                let node = TabSectionHeaderNode(content: header, inputs: inputs)
                nodes.append(node)
            case .spacer:
                nodes.append(SpacerViewNode(minLength: nil, content: Spacer()))
            case .divider:
                nodes.append(DividerNode(content: Divider()))
            }
        }
        return nodes
    }

    private static func buildContent(
        for selected: AnyHashable,
        from elements: [TabBarElement],
        inputs: _ViewInputs
    ) -> ViewNode {
        for element in elements {
            if case let .tab(_, _, value, makeContent) = element, value == selected {
                return makeContent(inputs)
            }
        }
        return EmptyView._makeView(_ViewGraphNode(value: EmptyView()), inputs: inputs).node
    }
}

// MARK: - Equal Width Tab Bar Layout

private struct EqualWidthTabBarLayout: Layout {
    typealias AnimatableData = EmptyAnimatableData
    static var layoutProperties = LayoutProperties(stackOrientation: .horizontal)

    func sizeThatFits(_ proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) -> Size {
        let width = proposal.width ?? (Float(subviews.count) * TabViewConstants.tabBarHeight)
        let height = proposal.height ?? TabViewConstants.tabBarHeight
        return Size(width: width, height: height)
    }

    func placeSubviews(in bounds: Rect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout Void) {
        guard !subviews.isEmpty else {
            return
        }
        let itemWidth = bounds.width / Float(subviews.count)
        var x = bounds.minX
        for subview in subviews {
            let childProposal = ProposedViewSize(width: itemWidth, height: bounds.height)
            subview.place(at: Point(x: x, y: bounds.midY), anchor: .leading, proposal: childProposal)
            x += itemWidth
        }
    }
}

// MARK: - Tab Item Button

private struct TabItemButton: View, ViewNodeBuilder {
    typealias Body = Never
    var body: Never { fatalError("Unreachable code") }

    let label: String?
    let image: Image?
    let value: AnyHashable
    let isSelected: Bool
    let isHorizontalBar: Bool
    let action: () -> Void

    func buildViewNode(in context: BuildContext) -> ViewNode {
        TabItemButtonNode(content: self, inputs: context)
    }
}

private final class TabItemButtonNode: ViewNode {
    private var label: String?
    private var image: Image?
    private var isSelected: Bool
    private var isHorizontalBar: Bool
    private var action: () -> Void
    private var isHighlighted: Bool = false
    private var iconTexture: Texture2D?
    private var touchStartLocation: Point?
    private(set) var value: AnyHashable

    init(content: TabItemButton, inputs: _ViewInputs) {
        self.label = content.label
        self.image = content.image
        self.isSelected = content.isSelected
        self.isHorizontalBar = content.isHorizontalBar
        self.action = content.action
        self.value = content.value
        self.iconTexture = content.image.map { Texture2D(image: $0) }
        super.init(content: content)
        self.updateEnvironment(inputs.environment)
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        if isHorizontalBar {
            let width = proposal.width ?? TabViewConstants.tabBarHeight
            let height = proposal.height ?? TabViewConstants.tabBarHeight
            return Size(width: width, height: height)
        } else {
            let width = proposal.width ?? TabViewConstants.tabBarWidth
            return Size(width: width, height: TabViewConstants.tabBarHeight)
        }
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event) else {
            return nil
        }
        return self
    }

    override func onMouseEvent(_ event: MouseEvent) {
        switch event.phase {
        case .began:
            isHighlighted = true
        case .changed:
            break
        case .ended:
            let was = isHighlighted
            isHighlighted = false
            if was {
                action()
            }
        case .cancelled:
            isHighlighted = false
        }
        requestDisplay()
    }

    override func onMouseLeave() {
        isHighlighted = false
        requestDisplay()
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        guard let touch = touches.first else {
            return
        }

        switch touch.phase {
        case .began:
            touchStartLocation = touch.location
            isHighlighted = true
        case .moved:
            if let start = touchStartLocation {
                let dx = touch.location.x - start.x
                let dy = touch.location.y - start.y
                let threshold = TabViewConstants.tapMovementThreshold
                if dx * dx + dy * dy > threshold * threshold {
                    isHighlighted = false
                }
            }
        case .ended:
            let was = isHighlighted
            isHighlighted = false
            touchStartLocation = nil
            if was {
                action()
            }
        case .cancelled:
            isHighlighted = false
            touchStartLocation = nil
        }

        requestDisplay()
    }

    override func draw(with context: UIGraphicsContext) {
        var ctx = context
        ctx.environment = environment
        ctx.translateBy(x: frame.origin.x, y: -frame.origin.y)

        let bounds = Rect(x: 0, y: 0, width: frame.width, height: frame.height)

        if isHighlighted {
            ctx.drawRect(bounds, color: TabViewConstants.highlightColor)
        }

        drawContent(in: bounds, with: ctx)
        drawIndicator(in: bounds, with: ctx)
    }

    override func update(from newNode: ViewNode) {
        super.update(from: newNode)
        guard let other = newNode as? TabItemButtonNode else {
            return
        }
        self.label = other.label
        self.image = other.image
        self.isSelected = other.isSelected
        self.isHorizontalBar = other.isHorizontalBar
        self.action = other.action
        self.value = other.value
        if let img = other.image, self.iconTexture == nil {
            self.iconTexture = Texture2D(image: img)
        }
    }

    func updateSelection(_ selected: AnyHashable) {
        let shouldBeSelected = AnyHashable(value) == selected
        guard isSelected != shouldBeSelected else {
            return
        }
        isSelected = shouldBeSelected
        requestDisplay()
    }

    // MARK: - Drawing helpers

    private func drawContent(in bounds: Rect, with context: UIGraphicsContext) {
        let isCompact = environment.tabLabelStyle == .compact
        let hasIcon = iconTexture != nil
        let hasLabel = !isCompact && label?.isEmpty == false

        switch (hasIcon, hasLabel) {
        case (true, false):
            drawIcon(centeredIn: bounds, with: context)
        case (false, true):
            drawLabel(centeredIn: bounds, with: context)
        case (true, true):
            if isHorizontalBar {
                drawIconAboveLabel(in: bounds, with: context)
            } else {
                drawIconBesideLabel(in: bounds, with: context)
            }
        default:
            break
        }
    }

    private func drawIcon(centeredIn bounds: Rect, with context: UIGraphicsContext) {
        guard let texture = iconTexture else {
            return
        }
        let size = TabViewConstants.iconSize
        let iconRect = Rect(
            x: (bounds.width - size) * 0.5,
            y: (bounds.height - size) * 0.5,
            width: size,
            height: size
        )
        let tint: Color = isSelected ? TabViewConstants.selectedTabTextColor : TabViewConstants.tabTextColor
        context.drawRect(iconRect, texture: texture, color: tint)
    }

    private func drawLabel(centeredIn bounds: Rect, with context: UIGraphicsContext) {
        guard let text = label, let font = resolvedFont() else {
            return
        }
        let pointSize = resolvedPointSize()
        let textColor: Color = isSelected ? TabViewConstants.selectedTabTextColor : TabViewConstants.tabTextColor
        renderText(text, font: font, color: textColor, centerX: bounds.width * 0.5, centerY: bounds.height * 0.5, pointSize: pointSize, in: context)
    }

    private func drawIconAboveLabel(in bounds: Rect, with context: UIGraphicsContext) {
        guard let texture = iconTexture, let text = label, let font = resolvedFont() else {
            return
        }
        let pointSize = resolvedPointSize()
        let tint: Color = isSelected ? TabViewConstants.selectedTabTextColor : TabViewConstants.tabTextColor
        let iconSize = TabViewConstants.iconSize
        let gap = TabViewConstants.iconTextGap
        let totalH = iconSize + gap + pointSize
        let startY = (bounds.height - totalH) * 0.5

        let iconRect = Rect(x: (bounds.width - iconSize) * 0.5, y: startY, width: iconSize, height: iconSize)
        context.drawRect(iconRect, texture: texture, color: tint)
        renderText(
            text,
            font: font,
            color: tint,
            centerX: bounds.width * 0.5,
            centerY: startY + iconSize + gap + pointSize * 0.5,
            pointSize: pointSize,
            in: context
        )
    }

    private func drawIconBesideLabel(in bounds: Rect, with context: UIGraphicsContext) {
        guard let texture = iconTexture, let text = label, let font = resolvedFont() else {
            return
        }
        let pointSize = resolvedPointSize()
        let tint: Color = isSelected ? TabViewConstants.selectedTabTextColor : TabViewConstants.tabTextColor
        let iconSize = TabViewConstants.iconSize
        let gap = TabViewConstants.iconTextGap
        let startX = TabViewConstants.tabHorizontalPadding

        let iconRect = Rect(x: startX, y: (bounds.height - iconSize) * 0.5, width: iconSize, height: iconSize)
        context.drawRect(iconRect, texture: texture, color: tint)
        renderText(
            text,
            font: font,
            color: tint,
            centerX: startX + iconSize + gap + estimatedTextWidth(text, pointSize: pointSize) * 0.5,
            centerY: bounds.height * 0.5,
            pointSize: pointSize,
            in: context
        )
    }

    private func drawIndicator(in bounds: Rect, with context: UIGraphicsContext) {
        guard isSelected else {
            return
        }
        let t = TabViewConstants.selectedIndicatorThickness
        switch isHorizontalBar {
        case true:
            // Indicator at bottom of button
            context.drawRect(
                Rect(x: 0, y: bounds.height - t, width: bounds.width, height: t),
                color: TabViewConstants.indicatorColor
            )
        case false:
            // Indicator on left edge of button
            context.drawRect(
                Rect(x: 0, y: 0, width: t, height: bounds.height),
                color: TabViewConstants.indicatorColor
            )
        }
    }

    private func renderText(
        _ text: String,
        font: Font,
        color: Color,
        centerX: Float,
        centerY: Float,
        pointSize: Float,
        in context: UIGraphicsContext
    ) {
        var attributes = TextAttributeContainer()
        attributes.font = font
        attributes.foregroundColor = color
        let attributedText = AttributedText(text, attributes: attributes)
        let container = TextContainer(text: attributedText, textAlignment: .center)
        let layoutManager = TextLayoutManager()
        layoutManager.setTextContainer(container)
        let textW = estimatedTextWidth(text, pointSize: pointSize)
        layoutManager.fitToSize(Size(width: textW + 4, height: pointSize * 2))

        let textX = centerX - textW * 0.5
        let textY = -(centerY + pointSize * 0.35)
        var ctx = context
        ctx.translateBy(x: textX, y: textY)
        for line in layoutManager.textLines {
            for run in line {
                for glyph in run {
                    ctx.draw(glyph)
                }
            }
        }
    }

    private func estimatedTextWidth(_ text: String, pointSize: Float) -> Float {
        Float(text.count) * pointSize * 0.55
    }

    private func resolvedPointSize() -> Float {
        environment.font.map { Float($0.pointSize) } ?? 14
    }

    private func resolvedFont() -> Font? {
        if let font = environment.font {
            return font
        }
        if unsafe RenderEngine.shared != nil {
            return .system(size: 14)
        }
        return nil
    }

    private func requestDisplay() {
        self.invalidateNearestLayer()
        self.owner?.containerView?.setNeedsDisplay(in: self.absoluteFrame())
    }
}

// MARK: - Tab Section Header

private struct TabSectionHeader: View, ViewNodeBuilder {
    typealias Body = Never
    var body: Never { fatalError("Unreachable code") }
    let title: String

    func buildViewNode(in context: BuildContext) -> ViewNode {
        TabSectionHeaderNode(content: self, inputs: context)
    }
}

private final class TabSectionHeaderNode: ViewNode {
    private var title: String

    init(content: TabSectionHeader, inputs: _ViewInputs) {
        self.title = content.title
        super.init(content: content)
        self.updateEnvironment(inputs.environment)
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        let width = proposal.width ?? TabViewConstants.tabBarWidth
        return Size(width: width, height: TabViewConstants.sectionHeaderHeight)
    }

    override func draw(with context: UIGraphicsContext) {
        var ctx = context
        ctx.environment = environment
        ctx.translateBy(x: frame.origin.x, y: -frame.origin.y)

        guard let font = resolvedFont() else {
            return
        }
        let pointSize = TabViewConstants.sectionHeaderFontSize
        var attributes = TextAttributeContainer()
        attributes.font = font
        attributes.foregroundColor = TabViewConstants.sectionHeaderColor
        let attributedText = AttributedText(title.uppercased(), attributes: attributes)
        let container = TextContainer(text: attributedText, textAlignment: .leading)
        let layoutManager = TextLayoutManager()
        layoutManager.setTextContainer(container)
        layoutManager.fitToSize(Size(width: frame.width, height: TabViewConstants.sectionHeaderHeight))

        let startX = TabViewConstants.tabHorizontalPadding
        let startY = -(frame.height * 0.5 + pointSize * 0.35)
        ctx.translateBy(x: startX, y: startY)
        for line in layoutManager.textLines {
            for run in line {
                for glyph in run {
                    ctx.draw(glyph)
                }
            }
        }
    }

    override func update(from newNode: ViewNode) {
        super.update(from: newNode)
        guard let other = newNode as? TabSectionHeaderNode else {
            return
        }
        self.title = other.title
    }

    private func resolvedFont() -> Font? {
        if unsafe RenderEngine.shared != nil {
            return .system(size: Double(TabViewConstants.sectionHeaderFontSize))
        }
        return nil
    }
}
