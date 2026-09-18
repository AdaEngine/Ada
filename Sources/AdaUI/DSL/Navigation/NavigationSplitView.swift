//
//  NavigationSplitView.swift
//  AdaEngine
//
//  Created by OpenAI on 29.04.2026.
//

import AdaAnimation
import AdaInput
import AdaText
import AdaUtils
import Math

/// The visibility of the leading columns in a navigation split view.
public enum NavigationSplitViewVisibility: Sendable, Hashable {
    case automatic
    case all
    case doubleColumn
    case detailOnly
}

/// A column in a navigation split view.
public enum NavigationSplitViewColumn: Sendable, Hashable {
    case sidebar
    case content
    case detail
}

/// A view that presents views in two or three resizable columns.
@MainActor @preconcurrency
public struct NavigationSplitView<Sidebar: View, Content: View, Detail: View>: View, ViewNodeBuilder {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    private let columnVisibility: Binding<NavigationSplitViewVisibility>?
    private let preferredCompactColumn: Binding<NavigationSplitViewColumn>?
    private let sidebar: () -> Sidebar
    private let content: (() -> Content)?
    private let detail: () -> Detail

    public init(
        columnVisibility: Binding<NavigationSplitViewVisibility>,
        preferredCompactColumn: Binding<NavigationSplitViewColumn>,
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.columnVisibility = columnVisibility
        self.preferredCompactColumn = preferredCompactColumn
        self.sidebar = sidebar
        self.content = content
        self.detail = detail
    }

    public init(
        columnVisibility: Binding<NavigationSplitViewVisibility>,
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.columnVisibility = columnVisibility
        self.preferredCompactColumn = nil
        self.sidebar = sidebar
        self.content = content
        self.detail = detail
    }

    public init(
        preferredCompactColumn: Binding<NavigationSplitViewColumn>,
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.columnVisibility = nil
        self.preferredCompactColumn = preferredCompactColumn
        self.sidebar = sidebar
        self.content = content
        self.detail = detail
    }

    public init(
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.columnVisibility = nil
        self.preferredCompactColumn = nil
        self.sidebar = sidebar
        self.content = content
        self.detail = detail
    }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let sidebarView = sidebar()
        let detailView = detail()
        let contentColumnNode: NavigationSplitColumnNode

        if let content {
            let contentView = content()
            contentColumnNode = makeColumnNode(column: .content, content: contentView, context: context)
        } else {
            let contentView = EmptyView()
            contentColumnNode = makeColumnNode(column: .content, content: contentView, context: context)
        }

        return NavigationSplitViewNode(
            inputs: context,
            content: self,
            columnVisibility: columnVisibility,
            preferredCompactColumn: preferredCompactColumn,
            hasContentColumn: content != nil,
            nodes: [
                makeColumnNode(column: .sidebar, content: sidebarView, context: context),
                NavigationSplitDividerNode(leadingColumn: .sidebar),
                contentColumnNode,
                NavigationSplitDividerNode(leadingColumn: .content),
                makeColumnNode(column: .detail, content: detailView, context: context),
            ]
        )
    }

    private func makeColumnNode<ColumnContent: View>(
        column: NavigationSplitViewColumn,
        content: ColumnContent,
        context: BuildContext
    ) -> NavigationSplitColumnNode {
        let contentNode = context.makeNode(from: content)
        if contentNode is NavigationStackNode {
            return NavigationSplitColumnNode(
                column: column,
                contentNode: contentNode,
                content: content
            )
        }

        let navigationStack = NavigationStack {
            content
        }
        return NavigationSplitColumnNode(
            column: column,
            contentNode: context.makeNode(from: navigationStack),
            content: navigationStack
        )
    }
}

@MainActor
extension NavigationSplitView where Content == EmptyView {
    public init(
        columnVisibility: Binding<NavigationSplitViewVisibility>,
        preferredCompactColumn: Binding<NavigationSplitViewColumn>,
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.columnVisibility = columnVisibility
        self.preferredCompactColumn = preferredCompactColumn
        self.sidebar = sidebar
        self.content = nil
        self.detail = detail
    }

    public init(
        columnVisibility: Binding<NavigationSplitViewVisibility>,
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.columnVisibility = columnVisibility
        self.preferredCompactColumn = nil
        self.sidebar = sidebar
        self.content = nil
        self.detail = detail
    }

    public init(
        preferredCompactColumn: Binding<NavigationSplitViewColumn>,
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.columnVisibility = nil
        self.preferredCompactColumn = preferredCompactColumn
        self.sidebar = sidebar
        self.content = nil
        self.detail = detail
    }

    public init(
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.columnVisibility = nil
        self.preferredCompactColumn = nil
        self.sidebar = sidebar
        self.content = nil
        self.detail = detail
    }
}

public struct NavigationSplitViewColumnWidth: Sendable, Equatable {
    public var min: Float?
    public var ideal: Float
    public var max: Float?

    public init(min: Float? = nil, ideal: Float, max: Float? = nil) {
        self.min = min
        self.ideal = ideal
        self.max = max
    }
}

/// The drawing behavior for separators in a navigation split view.
public enum NavigationSplitViewSeparatorVisibility: Sendable, Hashable {
    case visible
    case hidden
}

/// Configuration for separators in a navigation split view.
public struct NavigationSplitViewSeparatorConfiguration: Sendable, Equatable {
    public var visibility: NavigationSplitViewSeparatorVisibility
    public var color: Color
    public var allowsDragging: Bool
    public var hitOutset: Float

    public init(
        visibility: NavigationSplitViewSeparatorVisibility = .visible,
        color: Color = .gray,
        allowsDragging: Bool = true,
        hitOutset: Float = 5
    ) {
        self.visibility = visibility
        self.color = color
        self.allowsDragging = allowsDragging
        self.hitOutset = hitOutset
    }
}

extension View {
    /// Sets a fixed, preferred width for the column containing this view.
    public func navigationSplitViewColumnWidth(_ width: Float) -> some View {
        navigationSplitViewColumnWidth(min: width, ideal: width, max: width)
    }

    /// Sets minimum, ideal, and maximum preferred widths for the column containing this view.
    public func navigationSplitViewColumnWidth(min: Float? = nil, ideal: Float, max: Float? = nil) -> some View {
        preference(
            key: SplitColumnWidthPreferenceKey.self,
            value: NavigationSplitViewColumnWidth(min: min, ideal: ideal, max: max)
        )
    }

    /// Sets the style for navigation split views within this view.
    public func navigationSplitViewStyle<S: NavigationSplitViewStyle>(_: S) -> some View {
        self
    }

    /// Sets the separator configuration for navigation split views within this view.
    public func navigationSplitViewSeparators(_ configuration: NavigationSplitViewSeparatorConfiguration) -> some View {
        self.environment(\.navigationSplitViewSeparators, configuration)
    }

    /// Sets separator visibility, color, and drag behavior for navigation split views within this view.
    public func navigationSplitViewSeparators(
        _ visibility: NavigationSplitViewSeparatorVisibility = .visible,
        color: Color = .gray,
        allowsDragging: Bool = true,
        hitOutset: Float = 5
    ) -> some View {
        navigationSplitViewSeparators(
            NavigationSplitViewSeparatorConfiguration(
                visibility: visibility,
                color: color,
                allowsDragging: allowsDragging,
                hitOutset: hitOutset
            )
        )
    }
}

extension EnvironmentValues {
    @Entry public var navigationSplitViewSeparators: NavigationSplitViewSeparatorConfiguration = NavigationSplitViewSeparatorConfiguration()
}

public protocol NavigationSplitViewStyle {}

public struct AutomaticNavigationSplitViewStyle: NavigationSplitViewStyle, Sendable {
    public init() {}
}

public struct BalancedNavigationSplitViewStyle: NavigationSplitViewStyle, Sendable {
    public init() {}
}

public struct ProminentDetailNavigationSplitViewStyle: NavigationSplitViewStyle, Sendable {
    public init() {}
}

extension NavigationSplitViewStyle where Self == AutomaticNavigationSplitViewStyle {
    public static var automatic: AutomaticNavigationSplitViewStyle { AutomaticNavigationSplitViewStyle() }
}

extension NavigationSplitViewStyle where Self == BalancedNavigationSplitViewStyle {
    public static var balanced: BalancedNavigationSplitViewStyle { BalancedNavigationSplitViewStyle() }
}

extension NavigationSplitViewStyle where Self == ProminentDetailNavigationSplitViewStyle {
    public static var prominentDetail: ProminentDetailNavigationSplitViewStyle { ProminentDetailNavigationSplitViewStyle() }
}

private struct SplitColumnWidthPreferenceKey: PreferenceKey {
    static let defaultValue: NavigationSplitViewColumnWidth? = nil

    static func reduce(
        value: inout NavigationSplitViewColumnWidth?,
        nextValue: () -> NavigationSplitViewColumnWidth?
    ) {
        if let next = nextValue() {
            value = next
        }
    }
}

private struct NavigationSplitColumnSpec {
    var min: Float
    var ideal: Float
    var max: Float
}

private final class NavigationSplitColumnNode: ViewModifierNode {
    let column: NavigationSplitViewColumn
    private(set) var widthPreference: NavigationSplitViewColumnWidth?

    var navigationStackNode: NavigationStackNode? {
        contentNode as? NavigationStackNode
    }

    override var allowsNestedFrameAnimation: Bool {
        true
    }

    override func canAnimateNestedFrameChange(from oldFrame: Rect, to newFrame: Rect) -> Bool {
        oldFrame != newFrame
    }

    init<Content: View>(
        column: NavigationSplitViewColumn,
        contentNode: ViewNode,
        content: Content
    ) {
        self.column = column
        super.init(contentNode: contentNode, content: content)
    }

    override func updatePreference<K: PreferenceKey>(key: K.Type, value: K.Value) {
        if K.self == SplitColumnWidthPreferenceKey.self,
            let preference = value as? NavigationSplitViewColumnWidth? {
            widthPreference = preference
            (parent as? NavigationSplitViewNode)?.setWidthPreference(preference, for: column)
            return
        }

        super.updatePreference(key: key, value: value)
    }
}

private final class NavigationSplitDividerNode: ViewNode {
    let leadingColumn: NavigationSplitViewColumn
    private var lastDragX: Float?
    private var lastTouchX: Float?

    override var allowsNestedFrameAnimation: Bool {
        true
    }

    override func canAnimateNestedFrameChange(from oldFrame: Rect, to newFrame: Rect) -> Bool {
        oldFrame != newFrame
    }

    init(leadingColumn: NavigationSplitViewColumn) {
        self.leadingColumn = leadingColumn
        super.init(content: EmptyView())
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        Size(width: 1, height: proposal.height ?? 0)
    }

    override func draw(with context: UIGraphicsContext) {
        guard frame.width > 0, frame.height > 0 else {
            return
        }

        let separators = environment.navigationSplitViewSeparators
        guard separators.visibility == .visible, separators.color.alpha > 0 else {
            return
        }

        var context = context
        context.environment = environment
        context.translateBy(x: frame.origin.x, y: -frame.origin.y)
        context.drawRect(
            Rect(origin: .zero, size: Size(width: 1, height: frame.height)),
            color: separators.color
        )
    }

    override func point(inside point: Point, with _: any InputEvent) -> Bool {
        let separators = environment.navigationSplitViewSeparators
        guard separators.allowsDragging else {
            return false
        }

        return localHitBounds.contains(point: point)
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        self.point(inside: point, with: event) ? self : nil
    }

    override func onMouseEvent(_ event: MouseEvent) {
        guard environment.navigationSplitViewSeparators.allowsDragging else {
            return
        }

        switch event.phase {
        case .began:
            guard event.button == .left else {
                return
            }
            setResizeCursor()
            lastDragX = event.mousePosition.x
        case .changed:
            setResizeCursor()
            guard event.button == .left || event.button == .none, let lastDragX else {
                return
            }
            let delta = event.mousePosition.x - lastDragX
            self.lastDragX = event.mousePosition.x
            resizeLeadingColumn(by: delta)
        case .ended,
            .cancelled:
            lastDragX = nil
            if absoluteHitBounds.contains(point: event.mousePosition) {
                setResizeCursor()
            } else {
                resetCursor()
            }
        }
    }

    override func onMouseLeave() {
        resetCursor()
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        guard environment.navigationSplitViewSeparators.allowsDragging else {
            return
        }
        guard let first = touches.first else {
            return
        }

        switch first.phase {
        case .began:
            lastTouchX = first.location.x
        case .moved:
            guard let lastTouchX else {
                return
            }
            let delta = first.location.x - lastTouchX
            self.lastTouchX = first.location.x
            resizeLeadingColumn(by: delta)
        case .ended,
            .cancelled:
            lastTouchX = nil
        }
    }

    private func resizeLeadingColumn(by delta: Float) {
        guard delta != 0 else {
            return
        }
        (parent as? NavigationSplitViewNode)?.resizeColumn(leadingColumn, by: delta)
    }

    private var hitOutset: Float {
        max(environment.navigationSplitViewSeparators.hitOutset, 0)
    }

    private var localHitBounds: Rect {
        Rect(
            x: -hitOutset,
            y: 0,
            width: frame.width + hitOutset * 2,
            height: frame.height
        )
    }

    private var absoluteHitBounds: Rect {
        let bounds = absoluteFrame()
        return Rect(
            x: bounds.minX - hitOutset,
            y: bounds.minY,
            width: bounds.width + hitOutset * 2,
            height: bounds.height
        )
    }

    private func setResizeCursor() {
        owner?.window?.windowManager.setCursorShape(.resizeLeftRight)
    }

    private func resetCursor() {
        owner?.window?.windowManager.setCursorShape(.arrow)
    }

    override func updateEnvironment(_ parentEnvironment: EnvironmentValues) {
        let previousSeparators = environment.navigationSplitViewSeparators
        super.updateEnvironment(parentEnvironment)

        guard environment.navigationSplitViewSeparators != previousSeparators else {
            return
        }

        invalidateNearestLayer()
        owner?.containerView?.setNeedsDisplay(in: absoluteFrame())
    }
}

private final class NavigationSplitViewNode: ViewContainerNode, NavigationSplitDestinationRegistering {
    private static let compactWidthThreshold: Float = 620
    private static let dividerWidth: Float = 1
    private static let compactSwipeEdgeWidth: Float = 24
    private static let compactSwipeThreshold: Float = 72
    private static let compactSwipeMaximumVerticalDrift: Float = 56
    private static let compactTransitionAnimation = Animation.linear(duration: 0.24)

    private var viewInputs: _ViewInputs
    private var columnVisibility: Binding<NavigationSplitViewVisibility>?
    private var preferredCompactColumn: Binding<NavigationSplitViewColumn>?
    private var localPreferredCompactColumn = NavigationSplitViewColumn.detail
    private var hasContentColumn: Bool
    private var userWidths: [NavigationSplitViewColumn: Float] = [:]
    private var widthPreferences: [NavigationSplitViewColumn: NavigationSplitViewColumnWidth] = [:]
    private var destinationBuilders: [ObjectIdentifier: (AnyHashable, _ViewInputs) -> ViewNode?] = [:]
    private var compactSwipeStartPoint: Point?
    private var compactSwipeDidTrigger = false

    private lazy var compactBackAction = NavigationSplitCompactBackAction { [weak self] in
        self?.showCompactSidebar()
    }

    init<Content: View>(
        inputs: _ViewInputs,
        content: Content,
        columnVisibility: Binding<NavigationSplitViewVisibility>?,
        preferredCompactColumn: Binding<NavigationSplitViewColumn>?,
        hasContentColumn: Bool,
        nodes: [ViewNode]
    ) {
        self.viewInputs = inputs
        self.columnVisibility = columnVisibility
        self.preferredCompactColumn = preferredCompactColumn
        self.hasContentColumn = hasContentColumn
        super.init(content: content, nodes: nodes)
        syncColumnWidthPreferences()
        configureDividerCallbacks()
    }

    override func update(from newNode: ViewNode) {
        guard let other = newNode as? NavigationSplitViewNode else {
            super.update(from: newNode)
            return
        }

        viewInputs = other.viewInputs
        columnVisibility = other.columnVisibility
        preferredCompactColumn = other.preferredCompactColumn
        hasContentColumn = other.hasContentColumn
        super.update(from: other)
        syncColumnWidthPreferences()
        configureDividerCallbacks()
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        proposal.replacingUnspecifiedDimensions(by: Size(width: 720, height: 480))
    }

    override func performLayout() {
        let bounds = Rect(origin: .zero, size: frame.size)
        let columns = visibleColumns(for: frame.width)
        let widths = resolvedWidths(for: columns, totalWidth: frame.width)

        updateCompactBackActionEnvironments()
        layoutHiddenNodes(except: columns, in: bounds)

        var x = bounds.minX
        for (index, column) in columns.enumerated() {
            guard let node = columnNode(for: column) else {
                continue
            }
            let width = widths[column] ?? 0
            node.place(
                in: Point(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width

            guard
                index < columns.count - 1,
                let divider = dividerNode(after: column)
            else {
                continue
            }

            divider.place(
                in: Point(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: Self.dividerWidth, height: bounds.height)
            )
            x += Self.dividerWidth
        }

        invalidateLayerIfNeeded()
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event) else {
            return nil
        }

        if shouldCaptureCompactBackSwipe(at: point) {
            return self
        }

        for divider in drawableDividerNodes(for: frame.width).reversed() {
            let newPoint = divider.convert(point, from: self)
            if let hit = divider.hitTest(newPoint, with: event) {
                return hit
            }
        }

        for node in drawableColumnNodes(for: frame.width).reversed() {
            let newPoint = node.convert(point, from: self)
            if let hit = node.hitTest(newPoint, with: event) {
                return hit
            }
        }

        return self
    }

    override func draw(with context: UIGraphicsContext) {
        var context = context
        context.environment = environment
        context.translateBy(x: frame.origin.x, y: -frame.origin.y)

        let drawableDividers = drawableDividerNodes(for: frame.width)
        for node in nodes {
            if let columnNode = node as? NavigationSplitColumnNode,
                shouldDrawColumnNode(columnNode, width: frame.width) {
                columnNode.draw(with: context)
                continue
            }

            if let dividerNode = node as? NavigationSplitDividerNode,
                drawableDividers.contains(where: { $0 === dividerNode }) {
                dividerNode.draw(with: context)
            }
        }
    }

    override func updateEnvironment(_ parentEnvironment: EnvironmentValues) {
        super.updateEnvironment(parentEnvironment)
        viewInputs.environment = environment
        updateCompactBackActionEnvironments()
    }

    override func onMouseEvent(_ event: MouseEvent) {
        handleCompactBackSwipe(
            point: localPoint(fromWindowPoint: event.mousePosition),
            phase: event.phase
        )
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        guard let touch = touches.first else {
            return
        }
        handleCompactBackSwipe(
            point: localPoint(fromWindowPoint: touch.location),
            phase: touch.phase
        )
    }

    func setWidthPreference(_ preference: NavigationSplitViewColumnWidth?, for column: NavigationSplitViewColumn) {
        guard widthPreferences[column] != preference else {
            return
        }

        if let preference {
            widthPreferences[column] = preference
        } else {
            widthPreferences.removeValue(forKey: column)
        }
        performLayout()
        invalidateNearestLayer()
        owner?.containerView?.setNeedsDisplay(in: absoluteFrame())
    }

    func resizeColumn(_ column: NavigationSplitViewColumn, by delta: Float) {
        let columns = visibleColumns(for: frame.width)
        guard columns.contains(column), columns.last != column else {
            return
        }

        let currentWidths = resolvedWidths(for: columns, totalWidth: frame.width)
        guard let currentWidth = currentWidths[column] else {
            return
        }

        let spec = self.spec(for: column)
        let nextWidth = clamp(currentWidth + delta, min: spec.min, max: spec.max)
        userWidths[column] = nextWidth

        performLayout()
        invalidateNearestLayer()
        owner?.containerView?.setNeedsDisplay(in: absoluteFrame())
    }

    func navigate(_ value: AnyHashable, from column: NavigationSplitViewColumn) -> Bool {
        guard
            let targetColumn = navigationTarget(after: column),
            let targetContext = columnNode(for: targetColumn)?.navigationStackNode?.navigationContext
        else {
            return false
        }

        replayDestinationBuilders(to: targetContext)
        targetContext.push(value)

        if isCompactWidth(frame.width) {
            setCompactColumn(targetColumn)
        }

        return true
    }

    func registerDestinationBuilder(
        for identifier: ObjectIdentifier,
        builder: @escaping (AnyHashable, _ViewInputs) -> ViewNode?
    ) {
        destinationBuilders[identifier] = builder
        for columnNode in columnNodes() {
            if let context = columnNode.navigationStackNode?.navigationContext {
                context.registerDestinationBuilder(for: identifier, builder: builder)
            }
        }
    }

    private func configureDividerCallbacks() {
        // Dividers reach back to their parent dynamically during drag.
    }

    private func syncColumnWidthPreferences() {
        for columnNode in columnNodes() {
            if let preference = columnNode.widthPreference {
                widthPreferences[columnNode.column] = preference
            } else {
                widthPreferences.removeValue(forKey: columnNode.column)
            }
        }
    }

    private func navigationTarget(after column: NavigationSplitViewColumn) -> NavigationSplitViewColumn? {
        switch column {
        case .sidebar:
            return hasContentColumn ? .content : .detail
        case .content:
            return .detail
        case .detail:
            return nil
        }
    }

    private func replayDestinationBuilders(to context: NavigationContext) {
        for (identifier, builder) in destinationBuilders {
            context.registerDestinationBuilder(for: identifier, builder: builder)
        }
    }

    private func visibleColumns(for width: Float) -> [NavigationSplitViewColumn] {
        if width > 0 && width < Self.compactWidthThreshold {
            let preferred = currentCompactColumn
            if preferred == .content, hasContentColumn {
                return [.content]
            }
            if preferred == .sidebar {
                return [.sidebar]
            }
            return [.detail]
        }

        switch columnVisibility?.wrappedValue ?? .automatic {
        case .automatic,
            .all:
            return hasContentColumn ? [.sidebar, .content, .detail] : [.sidebar, .detail]
        case .doubleColumn:
            return hasContentColumn ? [.content, .detail] : [.sidebar, .detail]
        case .detailOnly:
            return [.detail]
        }
    }

    private var currentCompactColumn: NavigationSplitViewColumn {
        preferredCompactColumn?.wrappedValue ?? localPreferredCompactColumn
    }

    private func showCompactSidebar() {
        setCompactColumn(.sidebar)
    }

    private func setCompactColumn(_ column: NavigationSplitViewColumn) {
        guard currentCompactColumn != column else {
            return
        }

        let animationController = UIAnimationController(animation: Self.compactTransitionAnimation)
        performWithTransientAnimationController(animationController) {
            if let preferredCompactColumn {
                preferredCompactColumn.wrappedValue = column
            } else {
                localPreferredCompactColumn = column
            }
            performLayout()
            invalidateNearestLayer()
            owner?.containerView?.setNeedsDisplay(in: absoluteFrame())
        }
        owner?.addTransientAnimationController(animationController)
    }

    private func visibleDividerNodes(for width: Float) -> [NavigationSplitDividerNode] {
        let columns = visibleColumns(for: width)
        guard columns.count > 1 else {
            return []
        }

        return columns.dropLast().compactMap { dividerNode(after: $0) }
    }

    private func resolvedWidths(
        for columns: [NavigationSplitViewColumn],
        totalWidth: Float
    ) -> [NavigationSplitViewColumn: Float] {
        guard !columns.isEmpty else {
            return [:]
        }
        guard columns.count > 1 else {
            return [columns[0]: totalWidth]
        }

        let dividerTotal = Float(columns.count - 1) * Self.dividerWidth
        let available = max(totalWidth - dividerTotal, 0)
        var widths: [NavigationSplitViewColumn: Float] = [:]

        let leadingColumns = columns.dropLast()
        var used: Float = 0

        for column in leadingColumns {
            let spec = self.spec(for: column)
            let preferred = userWidths[column] ?? spec.ideal
            let width = clamp(preferred, min: spec.min, max: spec.max)
            widths[column] = width
            used += width
        }

        let detailColumn = columns[columns.count - 1]
        let detailSpec = spec(for: detailColumn)
        var detailWidth = available - used

        if detailWidth < detailSpec.min {
            var deficit = detailSpec.min - detailWidth
            for column in leadingColumns.reversed() {
                guard deficit > 0, let width = widths[column] else {
                    break
                }
                let minWidth = spec(for: column).min
                let reduction = min(width - minWidth, deficit)
                widths[column] = width - reduction
                deficit -= reduction
            }
            let updatedUsed = leadingColumns.reduce(Float.zero) { $0 + (widths[$1] ?? 0) }
            detailWidth = available - updatedUsed
        }

        widths[detailColumn] = max(detailWidth, 0)
        return widths
    }

    private func spec(for column: NavigationSplitViewColumn) -> NavigationSplitColumnSpec {
        let fallback: NavigationSplitColumnSpec
        switch column {
        case .sidebar:
            fallback = NavigationSplitColumnSpec(min: 180, ideal: 280, max: 420)
        case .content:
            fallback = NavigationSplitColumnSpec(min: 220, ideal: 320, max: 520)
        case .detail:
            fallback = NavigationSplitColumnSpec(min: 280, ideal: 480, max: .infinity)
        }

        guard let preference = widthPreferences[column] else {
            return fallback
        }

        let minWidth = preference.min ?? fallback.min
        let maxWidth = preference.max ?? fallback.max
        return NavigationSplitColumnSpec(
            min: minWidth,
            ideal: clamp(preference.ideal, min: minWidth, max: maxWidth),
            max: maxWidth
        )
    }

    private func layoutHiddenNodes(except visibleColumns: [NavigationSplitViewColumn], in bounds: Rect) {
        let visibleColumnSet = Set(visibleColumns)
        let visibleDividerSet = Set(visibleColumns.dropLast())

        for node in nodes {
            if let columnNode = node as? NavigationSplitColumnNode,
                visibleColumnSet.contains(columnNode.column) {
                continue
            }

            if let dividerNode = node as? NavigationSplitDividerNode,
                visibleDividerSet.contains(dividerNode.leadingColumn) {
                continue
            }

            if let columnNode = node as? NavigationSplitColumnNode {
                let hiddenFrame = hiddenFrame(for: columnNode.column, in: bounds)
                node.place(
                    in: hiddenFrame.origin,
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: hiddenFrame.width, height: hiddenFrame.height)
                )
                continue
            }

            if let dividerNode = node as? NavigationSplitDividerNode {
                let hiddenFrame = hiddenDividerFrame(after: dividerNode.leadingColumn, in: bounds)
                node.place(
                    in: hiddenFrame.origin,
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: hiddenFrame.width, height: hiddenFrame.height)
                )
                continue
            }

            node.place(in: .zero, anchor: .topLeading, proposal: .zero)
        }
    }

    private func hiddenFrame(for column: NavigationSplitViewColumn, in bounds: Rect) -> Rect {
        let width = hiddenWidth(for: column, totalWidth: bounds.width)

        switch column {
        case .sidebar:
            return Rect(x: bounds.minX - width, y: bounds.minY, width: width, height: bounds.height)
        case .content:
            return Rect(x: bounds.minX - width, y: bounds.minY, width: width, height: bounds.height)
        case .detail:
            return Rect(x: bounds.maxX, y: bounds.minY, width: width, height: bounds.height)
        }
    }

    private func hiddenDividerFrame(after column: NavigationSplitViewColumn, in bounds: Rect) -> Rect {
        switch column {
        case .sidebar,
            .content:
            return Rect(
                x: bounds.minX - Self.dividerWidth,
                y: bounds.minY,
                width: Self.dividerWidth,
                height: bounds.height
            )
        case .detail:
            return Rect(
                x: bounds.maxX,
                y: bounds.minY,
                width: Self.dividerWidth,
                height: bounds.height
            )
        }
    }

    private func hiddenWidth(for column: NavigationSplitViewColumn, totalWidth: Float) -> Float {
        let spec = spec(for: column)
        let preferred = userWidths[column] ?? spec.ideal
        return min(clamp(preferred, min: spec.min, max: spec.max), totalWidth)
    }

    private func drawableColumnNodes(for width: Float) -> [NavigationSplitColumnNode] {
        columnNodes().filter { shouldDrawColumnNode($0, width: width) }
    }

    private func drawableDividerNodes(for width: Float) -> [NavigationSplitDividerNode] {
        let visibleDividers = visibleDividerNodes(for: width)
        return nodes.compactMap { node -> NavigationSplitDividerNode? in
            guard let divider = node as? NavigationSplitDividerNode else {
                return nil
            }
            if visibleDividers.contains(where: { $0 === divider }) {
                return divider
            }
            return isTransitionFrameVisible(divider.frame) ? divider : nil
        }
    }

    private func shouldDrawColumnNode(_ node: NavigationSplitColumnNode, width: Float) -> Bool {
        if visibleColumns(for: width).contains(node.column) {
            return true
        }

        return isTransitionFrameVisible(node.frame)
    }

    private func isTransitionFrameVisible(_ frame: Rect) -> Bool {
        frame.width > 0
            && frame.height > 0
            && frame.maxX > 0
            && frame.minX < self.frame.width
    }

    private func columnNode(for column: NavigationSplitViewColumn) -> NavigationSplitColumnNode? {
        columnNodes().first { $0.column == column }
    }

    private func dividerNode(after column: NavigationSplitViewColumn) -> NavigationSplitDividerNode? {
        nodes.compactMap { $0 as? NavigationSplitDividerNode }.first { $0.leadingColumn == column }
    }

    private func columnNodes() -> [NavigationSplitColumnNode] {
        nodes.compactMap { $0 as? NavigationSplitColumnNode }
    }

    private func shouldShowCompactBackButton() -> Bool {
        isCompactWidth(frame.width) && currentCompactColumn != .sidebar
    }

    private func isCompactWidth(_ width: Float) -> Bool {
        width > 0 && width < Self.compactWidthThreshold
    }

    private func updateCompactBackActionEnvironments() {
        let shouldInstallBackAction = shouldShowCompactBackButton()
        for columnNode in columnNodes() {
            var columnEnvironment = environment
            let installsBackAction =
                shouldInstallBackAction
                && columnNode.column == currentCompactColumn
                && columnNode.column != .sidebar
            columnEnvironment.navigationSplitCompactBackAction = installsBackAction ? compactBackAction : nil
            columnEnvironment.navigationSplitColumnContext = NavigationSplitColumnContext(
                navigate: { [weak self, column = columnNode.column] value in
                    self?.navigate(value, from: column) ?? false
                },
                registerDestination: { [weak self] identifier, builder in
                    self?.registerDestinationBuilder(for: identifier, builder: builder)
                }
            )
            if let context = columnNode.navigationStackNode?.navigationContext {
                replayDestinationBuilders(to: context)
            }
            columnNode.updateEnvironment(columnEnvironment)
        }
    }

    private func shouldCaptureCompactBackSwipe(at point: Point) -> Bool {
        shouldShowCompactBackButton()
            && point.x >= 0
            && point.x <= Self.compactSwipeEdgeWidth
    }

    private func handleCompactBackSwipe(point: Point, phase: MouseEvent.Phase) {
        switch phase {
        case .began:
            compactSwipeStartPoint = shouldCaptureCompactBackSwipe(at: point) ? point : nil
            compactSwipeDidTrigger = false
        case .changed:
            updateCompactBackSwipe(to: point)
        case .ended,
            .cancelled:
            updateCompactBackSwipe(to: point)
            compactSwipeStartPoint = nil
            compactSwipeDidTrigger = false
        }
    }

    private func handleCompactBackSwipe(point: Point, phase: TouchEvent.Phase) {
        switch phase {
        case .began:
            compactSwipeStartPoint = shouldCaptureCompactBackSwipe(at: point) ? point : nil
            compactSwipeDidTrigger = false
        case .moved:
            updateCompactBackSwipe(to: point)
        case .ended,
            .cancelled:
            updateCompactBackSwipe(to: point)
            compactSwipeStartPoint = nil
            compactSwipeDidTrigger = false
        }
    }

    private func updateCompactBackSwipe(to point: Point) {
        guard !compactSwipeDidTrigger, let start = compactSwipeStartPoint else {
            return
        }

        let translationX = point.x - start.x
        let translationY = abs(point.y - start.y)
        guard
            translationX >= Self.compactSwipeThreshold,
            translationY <= Self.compactSwipeMaximumVerticalDrift
        else {
            return
        }

        compactSwipeDidTrigger = true
        showCompactSidebar()
    }

    private func localPoint(fromWindowPoint point: Point) -> Point {
        point - absoluteFrame().origin
    }

    private func clamp(_ value: Float, min minValue: Float, max maxValue: Float) -> Float {
        Swift.max(minValue, Swift.min(value, maxValue))
    }
}
