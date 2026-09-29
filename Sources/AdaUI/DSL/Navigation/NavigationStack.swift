//
//  NavigationStack.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 25.03.2026.
//

import AdaInput
import AdaText
import AdaUtils
import Math

// MARK: - NavigationContext

/// Shared mutable navigation state owned by a single NavigationStack.
/// Passed through the environment so descendants can push/pop/register destinations.
@MainActor
final class NavigationContext {
    private(set) var path: NavigationPath
    private var destinationBuilders: [ObjectIdentifier: (AnyHashable, _ViewInputs) -> ViewNode?] = [:]
    var onPathChanged: (() -> Void)?

    init(path: NavigationPath) {
        self.path = path
    }

    func push(_ value: AnyHashable) {
        path.append(value)
        onPathChanged?()
    }

    func pop() {
        guard !path.isEmpty else {
            return
        }
        path.removeLast()
        onPathChanged?()
    }

    func replacePath(_ newPath: NavigationPath) {
        path = newPath
    }

    func registerDestination<D: Hashable>(
        for type: D.Type,
        builder: @escaping (D, _ViewInputs) -> ViewNode
    ) {
        registerDestinationBuilder(for: ObjectIdentifier(type)) { anyValue, inputs in
            guard let typedValue = anyValue.base as? D else {
                return nil
            }
            return builder(typedValue, inputs)
        }
    }

    func registerDestinationBuilder(
        for identifier: ObjectIdentifier,
        builder: @escaping (AnyHashable, _ViewInputs) -> ViewNode?
    ) {
        destinationBuilders[identifier] = builder
    }

    func buildDestination(for value: AnyHashable, inputs: _ViewInputs) -> ViewNode? {
        for builder in destinationBuilders.values {
            if let node = builder(value, inputs) {
                return node
            }
        }
        return nil
    }
}

@MainActor
final class NavigationSplitCompactBackAction: @unchecked Sendable {
    let perform: @MainActor () -> Void

    init(_ perform: @escaping @MainActor () -> Void) {
        self.perform = perform
    }
}

@MainActor
final class NavigationSplitColumnContext: @unchecked Sendable {
    private let navigateHandler: @MainActor (AnyHashable) -> Bool
    private let destinationHandler:
        @MainActor (
            ObjectIdentifier,
            @escaping (AnyHashable, _ViewInputs) -> ViewNode?
        ) -> Void

    init(
        navigate: @MainActor @escaping (AnyHashable) -> Bool,
        registerDestination:
            @MainActor @escaping (
                ObjectIdentifier,
                @escaping (AnyHashable, _ViewInputs) -> ViewNode?
            ) -> Void
    ) {
        self.navigateHandler = navigate
        self.destinationHandler = registerDestination
    }

    func navigate(_ value: AnyHashable) -> Bool {
        navigateHandler(value)
    }

    func registerDestination<D: Hashable>(
        for type: D.Type,
        builder: @escaping (D, _ViewInputs) -> ViewNode
    ) {
        destinationHandler(ObjectIdentifier(type)) { anyValue, inputs in
            guard let typedValue = anyValue.base as? D else {
                return nil
            }
            return builder(typedValue, inputs)
        }
    }
}

@MainActor
protocol NavigationSplitDestinationRegistering: AnyObject {
    func registerDestinationBuilder(
        for identifier: ObjectIdentifier,
        builder: @escaping (AnyHashable, _ViewInputs) -> ViewNode?
    )
}

extension EnvironmentValues {
    /// The navigation bar's contribution to the content's top safe area.
    /// Use this as scroll content padding to start below the bar while scrolling underneath it.
    @Entry public var navigationBarContentInset: Float = 0
    @Entry var navigationContext: NavigationContext?
    @Entry internal var navigationSplitCompactBackAction: NavigationSplitCompactBackAction?
    @Entry internal var navigationSplitColumnContext: NavigationSplitColumnContext?
    @Entry internal var navigationBarConfiguration: NavigationBarConfiguration = NavigationBarConfiguration()
    @Entry internal var navigationBarLeadingItems: NavigationBarItemContent?
    @Entry internal var navigationBarTrailingItems: NavigationBarItemContent?
}

// MARK: - Navigation bar configuration

public enum NavigationTitlePosition: Hashable, Sendable {
    case automatic
    case leading
    case center
}

public enum NavigationBarTitleDisplayMode: Hashable, Sendable {
    case automatic
    case inline
    case large
}

struct NavigationBarConfiguration: Hashable, Sendable {
    var title: String?
    var titleFont: Font?
    var titlePosition: NavigationTitlePosition = .automatic
    var titleDisplayMode: NavigationBarTitleDisplayMode = .automatic
    var navigationBarColor: Color?
    var isHidden = false
    var backButtonHidden = false
}

/// Captures toolbar item builders that are evaluated only while constructing the
/// main-actor view tree.
final class NavigationBarItemContent: @unchecked Sendable {
    let makeNode: @MainActor (_ViewInputs) -> ViewNode

    @MainActor
    init<Content: View>(@ViewBuilder content: @MainActor @escaping () -> Content) {
        self.makeNode = { inputs in
            let view = content()
            return Content._makeView(_ViewGraphNode(value: view), inputs: inputs).node
        }
    }
}

extension View {
    public func navigationTitle(_ title: String) -> some View {
        self.transformEnvironment(\.navigationBarConfiguration) { configuration in
            configuration.title = title
        }
    }

    public func navigationTitle(_ title: Text) -> some View {
        self.navigationTitle(title.plainText)
    }

    /// Sets the navigation title font without changing content or toolbar item fonts.
    /// Pass `nil` to restore the default font for the title position.
    public func navigationTitleFont(_ font: Font?) -> some View {
        self.transformEnvironment(\.navigationBarConfiguration) { configuration in
            configuration.titleFont = font
        }
    }

    public func navigationTitlePosition(_ position: NavigationTitlePosition) -> some View {
        self.transformEnvironment(\.navigationBarConfiguration) { configuration in
            configuration.titlePosition = position
        }
    }

    /// Sets the base color used by the navigation bar's fading background gradient.
    /// Pass `nil` to restore the default black gradient.
    public func navigationBarColor(_ color: Color?) -> some View {
        self.transformEnvironment(\.navigationBarConfiguration) { configuration in
            configuration.navigationBarColor = color
        }
    }

    public func navigationBarTitleDisplayMode(_ mode: NavigationBarTitleDisplayMode) -> some View {
        self.transformEnvironment(\.navigationBarConfiguration) { configuration in
            configuration.titleDisplayMode = mode
        }
    }

    public func navigationBarBackButtonHidden(_ hidden: Bool = true) -> some View {
        self.transformEnvironment(\.navigationBarConfiguration) { configuration in
            configuration.backButtonHidden = hidden
        }
    }

    public func navigationBarHidden(_ hidden: Bool = true) -> some View {
        self.transformEnvironment(\.navigationBarConfiguration) { configuration in
            configuration.isHidden = hidden
        }
    }

    public func navigationBarLeadingItems<Content: View>(
        @ViewBuilder _ content: @MainActor @escaping () -> Content
    ) -> some View {
        self.environment(\.navigationBarLeadingItems, NavigationBarItemContent(content: content))
    }

    public func navigationBarTrailingItems<Content: View>(
        @ViewBuilder _ content: @MainActor @escaping () -> Content
    ) -> some View {
        self.environment(\.navigationBarTrailingItems, NavigationBarItemContent(content: content))
    }

    public func navigationBar<Leading: View, Trailing: View>(
        @ViewBuilder leadingItems: @MainActor @escaping () -> Leading,
        @ViewBuilder trailingItems: @MainActor @escaping () -> Trailing
    ) -> some View {
        self
            .environment(\.navigationBarLeadingItems, NavigationBarItemContent(content: leadingItems))
            .environment(\.navigationBarTrailingItems, NavigationBarItemContent(content: trailingItems))
    }
}

// MARK: - NavigationStack View

/// A view that displays a root view and enables you to present additional views over the root view.
///
/// Use `.navigate(for:destination:)` on child views to register destinations.
/// Drag right from the leading edge to reveal the previous screen interactively.
/// Releasing a short drag or cancelling the touch restores the current screen.
///
/// ```swift
/// NavigationStack {
///     ContentView()
///         .navigate(for: String.self) { value in
///             DetailView(id: value)
///         }
/// }
/// ```
@MainActor @preconcurrency
public struct NavigationStack<Content: View>: View, ViewNodeBuilder {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    let pathBinding: Binding<NavigationPath>
    let content: () -> Content
    let ownsPath: Bool

    /// Creates a navigation stack with a bound path.
    public init(path: Binding<NavigationPath>, @ViewBuilder content: @escaping () -> Content) {
        self.pathBinding = path
        self.content = content
        self.ownsPath = false
    }

    /// Creates a navigation stack with internal path state.
    public init(@ViewBuilder content: @escaping () -> Content) {
        var localPath = NavigationPath()
        self.pathBinding = Binding(
            get: { localPath },
            set: { localPath = $0 }
        )
        self.content = content
        self.ownsPath = true
    }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let navContext = NavigationContext(path: pathBinding.wrappedValue)
        let node = NavigationStackNode(
            inputs: context,
            pathBinding: pathBinding,
            navigationContext: navContext,
            ownsPath: ownsPath,
            contentBuilder: { inputs in
                let view = content()
                return Content._makeView(_ViewGraphNode(value: view), inputs: inputs).node
            }
        )
        navContext.onPathChanged = { [weak node] in
            node?.rebuildContent()
        }
        return node
    }
}

// MARK: - NavigationStackNode

final class NavigationStackNode: ViewNode, PresentationInputProviding {
    private enum Constants {
        static let navigationBarHeight: Float = 92
        static let backSwipeEdgeWidth: Float = 24
        static let backSwipeThreshold: Float = 72
        static let backSwipeMaximumVerticalDrift: Float = 56
        static let backSwipeMinimumDistance: Float = 8
    }

    private struct NavigationBarState {
        var configuration: NavigationBarConfiguration
        var leadingItems: NavigationBarItemContent?
        var trailingItems: NavigationBarItemContent?

        var hasExplicitValues: Bool {
            configuration != NavigationBarConfiguration()
                || leadingItems != nil
                || trailingItems != nil
        }
    }

    private var pathBinding: Binding<NavigationPath>
    private var ownsPath: Bool
    private(set) var navigationContext: NavigationContext
    private var viewInputs: _ViewInputs
    private var contentBuilder: (_ViewInputs) -> ViewNode
    private var currentContentNode: ViewNode
    private var navigationBarNode: NavigationBarNode?
    private var reservedNavigationBarHeight: Float = 0
    private var renderedPath = NavigationPath()
    private var retainedScreens: [NavigationPath: ViewNode] = [:]
    private(set) lazy var presentation = ViewPresentationTransition(host: self)
    private var contentBounds: Rect = .zero
    private var isReconciling = false
    private var backSwipeStartPoint: Point?
    private var backSwipeContactID: RID?
    private var backSwipeFailed = false
    private var backSwipePopPending = false
    private var backSwipePopTask: Task<Void, Never>?
    private var backSwipeSettling = false

    private var backSwipeBlocksInput: Bool {
        backSwipeContactID != nil || backSwipePopPending || presentation.isInteractive || backSwipeSettling
    }

    private lazy var dismissAction = DismissAction { [weak self] in
        self?.navigationContext.pop()
    }

    /// Subtree searched for keyboard shortcut targets (matches visible stack content).
    var shortcutContentSubtree: ViewNode {
        currentContentNode
    }

    /// Visible subtrees exposed to AdaUI inspection and automation.
    var inspectionChildNodes: [ViewNode] {
        [navigationBarNode].compactMap { $0 } + presentation.nodes
    }

    override var transientEnvironmentChildren: [ViewNode] { inspectionChildNodes }
    var inputContentNodes: [ViewNode] {
        backSwipeBlocksInput ? [] : [navigationBarNode, currentContentNode].compactMap { $0 }
    }

    init(
        inputs: _ViewInputs,
        pathBinding: Binding<NavigationPath>,
        navigationContext: NavigationContext,
        ownsPath: Bool = false,
        contentBuilder: @escaping (_ViewInputs) -> ViewNode
    ) {
        self.pathBinding = pathBinding
        self.ownsPath = ownsPath
        self.navigationContext = navigationContext
        self.viewInputs = inputs
        self.contentBuilder = contentBuilder

        // Always build root first so .navigate(for:) modifiers register destinations.
        let childInputs = Self.makeChildInputs(from: inputs, context: navigationContext)
        self.currentContentNode = contentBuilder(childInputs)

        super.init(content: AnyView(EmptyView()))
        currentContentNode.parent = self
        retainedScreens[NavigationPath()] = currentContentNode
        presentation.setContent(currentContentNode, style: .push, animated: false)
        syncNavigationBar()

        // If the path already has values (e.g. binding was pre-populated),
        // switch to the appropriate destination now that it's been registered.
        if !navigationContext.path.isEmpty {
            rebuildContent(syncBinding: false)
        }
    }

    func rebuildContent(syncBinding: Bool = true) {
        let childInputs = Self.makeChildInputs(
            from: viewInputs,
            context: navigationContext,
            dismiss: dismissAction
        )

        let newNode: ViewNode
        if let topValue = navigationContext.path.topElement,
            let destNode = navigationContext.buildDestination(for: topValue, inputs: childInputs) {
            newNode = destNode
        } else {
            newNode = contentBuilder(childInputs)
        }

        let nextPath = navigationContext.path
        let pathChanged = renderedPath != nextPath
        if pathChanged {
            resetBackSwipe()
            backSwipePopTask?.cancel()
            backSwipePopTask = nil
            backSwipePopPending = false
            presentation.endInteractiveTransition(completing: false, animated: false)
        }
        let style: ViewPresentationTransition.Style = nextPath.count < renderedPath.count ? .pop : .push
        if let retained = retainedScreens[nextPath], newNode.canUpdate(retained) {
            retained.update(from: newNode)
            currentContentNode = retained
        } else {
            currentContentNode = newNode
            retainedScreens[nextPath] = newNode
        }
        renderedPath = nextPath
        retainedScreens = retainedScreens.filter { $0.key.isPrefix(of: nextPath) }
        presentation.setContent(currentContentNode, style: style, animated: pathChanged)

        currentContentNode.updateEnvironment(childInputs.environment)
        syncNavigationBar()
        invalidateNearestLayer()
        owner?.containerView?.setNeedsDisplay(in: absoluteFrame())
        performLayout()

        if syncBinding {
            pathBinding.wrappedValue = navigationContext.path
        }
    }

    private static func makeChildInputs(
        from inputs: _ViewInputs,
        context: NavigationContext,
        dismiss: DismissAction? = nil
    ) -> _ViewInputs {
        var childInputs = inputs
        childInputs.environment.navigationContext = context
        childInputs.environment.navigationSplitCompactBackAction = nil
        if let dismiss {
            childInputs.environment.dismiss = dismiss
        }
        return childInputs
    }

    private func makeContentInputs(reservingNavigationBarHeight height: Float) -> _ViewInputs {
        var inputs = Self.makeChildInputs(
            from: viewInputs,
            context: navigationContext,
            dismiss: dismissAction
        )
        if height > 0 {
            inputs.environment.safeAreaInsets.top += height
        }
        inputs.environment.navigationBarContentInset = height
        return inputs
    }

    private var navigationBarChromeTopInset: Float {
        max(0, viewInputs.environment.navigationBarChromeInsets.top)
    }

    private var totalNavigationBarReservedHeight: Float {
        navigationBarChromeTopInset + Constants.navigationBarHeight
    }

    private func syncNavigationBar() {
        var state = Self.navigationBarState(in: currentContentNode)
        let configuration = state.configuration
        let showsBackButton = !navigationContext.path.isEmpty && !configuration.backButtonHidden
        let splitBackAction =
            configuration.backButtonHidden
            ? nil
            : viewInputs.environment.navigationSplitCompactBackAction
        let showsNavigationBar = !configuration.isHidden

        let contentReceivesTopSafeArea = showsNavigationBar && Self.nodeConsumesTopSafeArea(currentContentNode)
        let reservedHeight = showsNavigationBar ? totalNavigationBarReservedHeight : 0
        let contentSafeAreaHeight = contentReceivesTopSafeArea ? reservedHeight : 0
        reservedNavigationBarHeight = reservedHeight

        let contentInputs = makeContentInputs(reservingNavigationBarHeight: contentSafeAreaHeight)
        currentContentNode.updateEnvironment(contentInputs.environment)
        state = Self.navigationBarState(in: currentContentNode)

        guard showsNavigationBar else {
            navigationBarNode?.parent = nil
            navigationBarNode = nil
            return
        }

        var barInputs = Self.makeChildInputs(
            from: viewInputs,
            context: navigationContext,
            dismiss: dismissAction
        )
        barInputs.environment = currentContentNode.environment
        barInputs.environment.navigationContext = navigationContext
        barInputs.environment.dismiss = dismissAction

        if let navigationBarNode {
            navigationBarNode.update(
                configuration: state.configuration,
                leadingItems: state.leadingItems,
                trailingItems: state.trailingItems,
                splitBackAction: splitBackAction,
                showsBackButton: showsBackButton,
                inputs: barInputs
            )
        } else {
            let node = NavigationBarNode(
                configuration: state.configuration,
                leadingItems: state.leadingItems,
                trailingItems: state.trailingItems,
                splitBackAction: splitBackAction,
                showsBackButton: showsBackButton,
                navigationContext: navigationContext,
                inputs: barInputs
            )
            node.parent = self
            if let owner {
                node.updateViewOwner(owner)
            }
            navigationBarNode = node
        }
    }

    // MARK: - ViewNode overrides

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        let contentSize = currentContentNode.sizeThatFits(proposal)
        return Size(width: proposal.width ?? contentSize.width, height: proposal.height ?? contentSize.height)
    }

    override func performLayout() {
        contentBounds = contentLayoutBounds(for: currentContentNode)
        presentation.layout(in: contentBounds, boundsForNode: contentLayoutBounds(for:))
        navigationBarNode?
            .place(
                in: .zero,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: totalNavigationBarReservedHeight)
            )
    }

    private func contentLayoutBounds(for node: ViewNode) -> Rect {
        let configuration = Self.navigationBarState(in: node).configuration
        let placesBelowBar = !configuration.isHidden && !Self.nodeConsumesTopSafeArea(node)
        let originY: Float = placesBelowBar ? totalNavigationBarReservedHeight : 0
        return Rect(origin: Point(0, originY), size: Size(width: frame.width, height: max(0, frame.height - originY)))
    }

    override func updateEnvironment(_ environment: EnvironmentValues) {
        let prevVersion = self.environment.version
        super.updateEnvironment(environment)
        guard self.environment.version != prevVersion else {
            return
        }
        viewInputs.environment = self.environment
        syncNavigationBar()
    }

    override func update(from newNode: ViewNode) {
        guard let other = newNode as? NavigationStackNode else {
            return
        }

        isReconciling = true
        defer { isReconciling = false }
        if !ownsPath || !other.ownsPath { pathBinding = other.pathBinding }
        ownsPath = other.ownsPath
        let boundPath = pathBinding.wrappedValue
        viewInputs = other.viewInputs
        contentBuilder = other.contentBuilder
        navigationContext.replacePath(boundPath)
        super.update(from: other)
        rebuildContent(syncBinding: false)
    }

    private static func navigationBarState(in node: ViewNode) -> NavigationBarState {
        if let modifier = node as? ViewModifierNode {
            let childState = navigationBarState(in: modifier.contentNode)
            if childState.hasExplicitValues {
                return childState
            }
        }

        if let container = node as? ViewContainerNode {
            for child in container.nodes {
                let childState = navigationBarState(in: child)
                if childState.hasExplicitValues {
                    return childState
                }
            }
        }

        return NavigationBarState(
            configuration: node.environment.navigationBarConfiguration,
            leadingItems: node.environment.navigationBarLeadingItems,
            trailingItems: node.environment.navigationBarTrailingItems
        )
    }

    private static func nodeConsumesTopSafeArea(_ node: ViewNode) -> Bool {
        if let scrollView = node as? ScrollViewNode {
            return scrollView.environment._scrollViewRespectsSafeArea
        }

        if let modifier = node as? ViewModifierNode {
            return nodeConsumesTopSafeArea(modifier.contentNode)
        }

        if let container = node as? ViewContainerNode {
            return container.nodes.contains { child in
                nodeConsumesTopSafeArea(child)
            }
        }

        // Active tab pages are exposed through presentation nodes, including
        // the content proxy embedded in a custom style.
        if !(node is NavigationStackNode), let presentation = node as? any PresentationInputProviding {
            return presentation.inputContentNodes.contains { child in
                nodeConsumesTopSafeArea(child)
            }
        }

        return false
    }

    override func updateViewOwner(_ owner: ViewOwner) {
        super.updateViewOwner(owner)
        presentation.nodes.forEach { $0.updateViewOwner(owner) }
        navigationBarNode?.updateViewOwner(owner)
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event) else {
            return nil
        }
        if backSwipeBlocksInput {
            return self
        }
        if let navigationBarNode {
            let barPoint = navigationBarNode.convert(point, from: self)
            if let hit = navigationBarNode.hitTest(barPoint, with: event) {
                return hit
            }
        }
        if event is TouchEvent, shouldCaptureBackSwipe(at: point) {
            return self
        }
        return presentation.hitTest(point, event: event, in: contentBounds)
    }

    override func draw(with context: UIGraphicsContext) {
        var context = context
        context.environment = environment
        context.translateBy(x: frame.origin.x, y: -frame.origin.y)
        presentation.draw(with: context, in: Rect(origin: .zero, size: frame.size))
        navigationBarNode?.draw(with: context)
    }

    override func update(_ deltaTime: TimeInterval) {
        if navigationContext.path != pathBinding.wrappedValue {
            navigationContext.replacePath(pathBinding.wrappedValue)
            rebuildContent(syncBinding: false)
        }
        presentation.update(deltaTime)
        if !presentation.isInteractive, !presentation.isAnimating { backSwipeSettling = false }
        navigationBarNode?.update(deltaTime)
    }

    override func findNodeById(_ id: AnyHashable) -> ViewNode? {
        navigationBarNode?.findNodeById(id) ?? currentContentNode.findNodeById(id)
    }

    override func findNodyByAccessibilityIdentifier(_ identifier: String) -> ViewNode? {
        super.findNodyByAccessibilityIdentifier(identifier)
            ?? navigationBarNode?.findNodyByAccessibilityIdentifier(identifier)
            ?? currentContentNode.findNodyByAccessibilityIdentifier(identifier)
    }

    override func invalidateContent() {
        guard !isReconciling else {
            return
        }
        navigationContext.replacePath(pathBinding.wrappedValue)
        rebuildContent(syncBinding: false)
    }

    override func didMove(to parent: ViewNode?) {
        super.didMove(to: parent)
        if parent == nil {
            resetBackSwipe()
            backSwipePopTask?.cancel()
            backSwipePopTask = nil
            backSwipePopPending = false
            backSwipeSettling = false
            presentation.detach()
            navigationBarNode?.parent = nil
        } else {
            presentation.setContent(currentContentNode, style: .push, animated: false)
            navigationBarNode?.parent = self
        }
    }

    override func onMouseEvent(_ event: MouseEvent) {
        guard !backSwipeBlocksInput else {
            return
        }
        currentContentNode.onMouseEvent(event)
        navigationBarNode?.onMouseEvent(event)
    }

    override func onReceiveEvent(_ event: any InputEvent) {
        guard !backSwipeBlocksInput else {
            return
        }
        currentContentNode.onReceiveEvent(event)
        navigationBarNode?.onReceiveEvent(event)
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        if let touch = touches.first(where: { $0.contactID == backSwipeContactID }) ?? touches.first, handleBackSwipe(touch) {
            return
        }
        guard !backSwipeBlocksInput else {
            return
        }
        currentContentNode.onTouchesEvent(touches)
        navigationBarNode?.onTouchesEvent(touches)
    }

    private func shouldCaptureBackSwipe(at point: Point) -> Bool {
        !navigationContext.path.isEmpty
            && !presentation.isAnimating
            && !presentation.isInteractive
            && backSwipeContactID == nil
            && !backSwipePopPending
            && !Self.navigationBarState(in: currentContentNode).configuration.backButtonHidden
            && point.x >= 0
            && point.x <= Constants.backSwipeEdgeWidth
            && point.y >= reservedNavigationBarHeight
    }

    private func handleBackSwipe(_ touch: TouchEvent) -> Bool {
        let point = touch.location - absoluteFrame().origin
        switch touch.phase {
        case .began:
            guard shouldCaptureBackSwipe(at: point) else {
                return false
            }
            backSwipeStartPoint = point
            backSwipeContactID = touch.contactID
            backSwipeFailed = false
            return true
        case .moved:
            guard touch.contactID == backSwipeContactID, let start = backSwipeStartPoint else {
                return false
            }
            if abs(point.y - start.y) > Constants.backSwipeMaximumVerticalDrift {
                backSwipeFailed = true
                presentation.endInteractiveTransition(completing: false)
            }
            if !backSwipeFailed { updateBackSwipe(at: point, from: start) }
            return true
        case .ended:
            guard touch.contactID == backSwipeContactID, let start = backSwipeStartPoint else {
                return false
            }
            let shouldPop = !backSwipeFailed
                && point.x - start.x >= Constants.backSwipeThreshold
                && abs(point.y - start.y) <= Constants.backSwipeMaximumVerticalDrift
            if !backSwipeFailed { updateBackSwipe(at: point, from: start) }
            resetBackSwipe()
            if shouldPop, presentation.isInteractive {
                // Without a settling animation, retain the outgoing native views
                // until UIKit has finished dispatching this touch.
                if !environment.animationsDisabled {
                    presentation.endInteractiveTransition(completing: true)
                }
                scheduleBackSwipePop()
            } else {
                presentation.endInteractiveTransition(completing: false)
            }
            return true
        case .cancelled:
            guard touch.contactID == backSwipeContactID else {
                return false
            }
            resetBackSwipe()
            presentation.endInteractiveTransition(completing: false)
            return true
        }
    }

    private func updateBackSwipe(at point: Point, from start: Point) {
        let distance = max(0, point.x - start.x)
        if !presentation.isInteractive, distance >= Constants.backSwipeMinimumDistance,
           distance > abs(point.y - start.y), frame.width > 0 {
            var previousPath = renderedPath
            previousPath.removeLast()
            let inputs = Self.makeChildInputs(from: viewInputs, context: navigationContext, dismiss: dismissAction)
            let updated: ViewNode
            if let value = previousPath.topElement,
               let destination = navigationContext.buildDestination(for: value, inputs: inputs) {
                updated = destination
            } else {
                updated = contentBuilder(inputs)
            }
            let previous: ViewNode
            if let retained = retainedScreens[previousPath], updated.canUpdate(retained) {
                retained.update(from: updated)
                previous = retained
            } else {
                previous = updated
                retainedScreens[previousPath] = previous
            }
            let configuration = Self.navigationBarState(in: previous).configuration
            let safeAreaHeight = !configuration.isHidden && Self.nodeConsumesTopSafeArea(previous) ? totalNavigationBarReservedHeight : 0
            previous.updateEnvironment(makeContentInputs(reservingNavigationBarHeight: safeAreaHeight).environment)
            presentation.beginInteractiveTransition(to: previous, style: .pop)
            if let navigationBarNode { owner?.deactivateInput(in: navigationBarNode) }
            backSwipeSettling = true
            performLayout()
        }
        if frame.width > 0 { presentation.updateInteractiveTransition(progress: distance / frame.width) }
    }

    private func resetBackSwipe() {
        backSwipeStartPoint = nil
        backSwipeContactID = nil
        backSwipeFailed = false
    }

    private func scheduleBackSwipePop() {
        guard !backSwipePopPending else {
            return
        }
        backSwipePopPending = true
        let expectedPath = navigationContext.path
        backSwipePopTask = Task { @MainActor [weak self] in
            do {
                // UIKit must finish dispatching the touch before the current screen is removed.
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return
            }
            guard let self else {
                return
            }
            self.backSwipePopPending = false
            self.backSwipePopTask = nil
            guard self.navigationContext.path == expectedPath, self.pathBinding.wrappedValue == expectedPath else {
                self.navigationContext.replacePath(self.pathBinding.wrappedValue)
                self.rebuildContent(syncBinding: false)
                return
            }
            self.presentation.endInteractiveTransition(completing: true)
            self.navigationContext.pop()
        }
    }
}

// MARK: - NavigationBarNode

final class NavigationBarNode: ViewNode {
    private enum Constants {
        static let height: Float = 92
        static let horizontalPadding: Float = 16
        static let itemSpacing: Float = 10
        static let controlHeight: Float = 44
        static let titleHorizontalInset: Float = 72
        static let leadingTitleOffset: Float = 54
        static let minimumCenteredTitleWidth: Float = 120
    }

    private var configuration: NavigationBarConfiguration
    private var leadingItems: NavigationBarItemContent?
    private var trailingItems: NavigationBarItemContent?
    private var splitBackAction: NavigationSplitCompactBackAction?
    private var showsBackButton: Bool
    private weak var navigationContext: NavigationContext?
    private var inputs: _ViewInputs

    private var titleNode: ViewNode?
    private var splitBackButtonNode: ViewNode?
    private var backButtonNode: ViewNode?
    private var leadingItemsNode: ViewNode?
    private var trailingItemsNode: ViewNode?

    private var chromeTopInset: Float {
        max(0, environment.navigationBarChromeInsets.top)
    }

    var resolvedBackgroundColor: Color {
        configuration.navigationBarColor ?? .black
    }

    init(
        configuration: NavigationBarConfiguration,
        leadingItems: NavigationBarItemContent?,
        trailingItems: NavigationBarItemContent?,
        splitBackAction: NavigationSplitCompactBackAction?,
        showsBackButton: Bool,
        navigationContext: NavigationContext,
        inputs: _ViewInputs
    ) {
        self.configuration = configuration
        self.leadingItems = leadingItems
        self.trailingItems = trailingItems
        self.splitBackAction = splitBackAction
        self.showsBackButton = showsBackButton
        self.navigationContext = navigationContext
        self.inputs = inputs
        super.init(content: AnyView(EmptyView()))
        rebuildChildren()
        updateEnvironment(inputs.environment)
    }

    func update(
        configuration: NavigationBarConfiguration,
        leadingItems: NavigationBarItemContent?,
        trailingItems: NavigationBarItemContent?,
        splitBackAction: NavigationSplitCompactBackAction?,
        showsBackButton: Bool,
        inputs: _ViewInputs
    ) {
        self.configuration = configuration
        self.leadingItems = leadingItems
        self.trailingItems = trailingItems
        self.splitBackAction = splitBackAction
        self.showsBackButton = showsBackButton
        self.inputs = inputs
        rebuildChildren()
        updateEnvironment(inputs.environment)
        performLayout()
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        Size(width: proposal.width ?? 0, height: chromeTopInset + Constants.height)
    }

    override func performLayout() {
        let titlePosition = resolvedTitlePosition()
        let centerY = chromeTopInset + Constants.height * 0.5
        var leadingX = Constants.horizontalPadding
        let reservedTitleWidth =
            titlePosition == .center || titlePosition == .automatic
            ? Constants.minimumCenteredTitleWidth
            : 0
        let maxItemWidth = max(
            0,
            (frame.width - Constants.horizontalPadding * 2 - reservedTitleWidth - Constants.itemSpacing * 2) * 0.5
        )

        if let splitBackButtonNode {
            splitBackButtonNode.place(
                in: Point(x: leadingX, y: centerY),
                anchor: .leading,
                proposal: ProposedViewSize(width: Constants.controlHeight, height: Constants.controlHeight)
            )
            leadingX += Constants.controlHeight + Constants.itemSpacing
        }

        if let backButtonNode {
            backButtonNode.place(
                in: Point(x: leadingX, y: centerY),
                anchor: .leading,
                proposal: ProposedViewSize(width: Constants.controlHeight, height: Constants.controlHeight)
            )
            leadingX += Constants.controlHeight + Constants.itemSpacing
        }

        if let leadingItemsNode {
            let measured = leadingItemsNode.sizeThatFits(.unspecified)
            let width = min(measured.width, maxItemWidth)
            leadingItemsNode.place(
                in: Point(x: leadingX, y: centerY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: Constants.controlHeight)
            )
            leadingX += width + Constants.itemSpacing
        }

        var trailingWidth: Float = 0
        if let trailingItemsNode {
            let measured = trailingItemsNode.sizeThatFits(.unspecified)
            trailingWidth = min(measured.width, maxItemWidth)
            trailingItemsNode.place(
                in: Point(x: frame.width - Constants.horizontalPadding, y: centerY),
                anchor: .trailing,
                proposal: ProposedViewSize(width: trailingWidth, height: Constants.controlHeight)
            )
        }

        if let titleNode {
            switch titlePosition {
            case .leading:
                let availableWidth = max(0, frame.width - leadingX - Constants.horizontalPadding)
                titleNode.place(
                    in: Point(x: leadingX, y: centerY),
                    anchor: .leading,
                    proposal: ProposedViewSize(width: availableWidth, height: Constants.controlHeight)
                )
            case .automatic,
                .center:
                let occupiedSideWidth = max(
                    leadingX,
                    Constants.horizontalPadding + trailingWidth + Constants.itemSpacing
                )
                titleNode.place(
                    in: Point(x: frame.width * 0.5, y: centerY),
                    anchor: .center,
                    proposal: ProposedViewSize(
                        width: max(0, frame.width - occupiedSideWidth * 2),
                        height: Constants.controlHeight
                    )
                )
            }
        }
    }

    override func updateEnvironment(_ environment: EnvironmentValues) {
        let prevVersion = self.environment.version
        super.updateEnvironment(environment)
        guard self.environment.version != prevVersion else {
            return
        }
        inputs.environment = self.environment
        updateChildEnvironments()
    }

    override func updateViewOwner(_ owner: ViewOwner) {
        super.updateViewOwner(owner)
        for node in childNodes {
            node.updateViewOwner(owner)
        }
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event) else {
            return nil
        }
        for node in childNodes.reversed() {
            let childPoint = node.convert(point, from: self)
            if let hit = node.hitTest(childPoint, with: event) {
                return hit
            }
        }
        return nil
    }

    override func point(inside point: Point, with event: any InputEvent) -> Bool {
        super.point(inside: point, with: event)
            || childNodes.contains { node in
                let childPoint = node.convert(point, from: self)
                return node.point(inside: childPoint, with: event)
            }
    }

    override func draw(with context: UIGraphicsContext) {
        var context = context
        context.environment = environment
        let navigationBarColor = resolvedBackgroundColor
        context.translateBy(x: frame.origin.x, y: -frame.origin.y)
        context.drawLinearGradient(
            ResolvedLinearGradient(
                startPoint: .top,
                endPoint: .bottom,
                stops: [
                    Gradient.Stop(color: navigationBarColor.opacity(0.98), location: 0),
                    Gradient.Stop(color: navigationBarColor.opacity(0.72), location: 0.48),
                    Gradient.Stop(color: navigationBarColor.opacity(0), location: 1),
                ]
            ),
            in: Rect(origin: .zero, size: frame.size)
        )
        for node in childNodes {
            node.draw(with: context)
        }
    }

    override func update(_ deltaTime: TimeInterval) {
        for node in childNodes {
            node.update(deltaTime)
        }
    }

    override func findNodeById(_ id: AnyHashable) -> ViewNode? {
        childNodes.lazy.compactMap { $0.findNodeById(id) }.first
    }

    override func findNodyByAccessibilityIdentifier(_ identifier: String) -> ViewNode? {
        super.findNodyByAccessibilityIdentifier(identifier)
            ?? childNodes.lazy.compactMap { $0.findNodyByAccessibilityIdentifier(identifier) }.first
    }

    override func didMove(to parent: ViewNode?) {
        super.didMove(to: parent)
        if parent == nil {
            for node in childNodes {
                node.parent = nil
            }
        } else {
            for node in childNodes { node.parent = self }
        }
    }

    private var childNodes: [ViewNode] {
        [
            titleNode,
            splitBackButtonNode,
            backButtonNode,
            leadingItemsNode,
            trailingItemsNode,
        ]
        .compactMap { $0 }
    }

    var inspectionChildNodes: [ViewNode] {
        childNodes
    }

    private func rebuildChildren() {
        for node in childNodes {
            node.parent = nil
        }

        titleNode = makeTitleNode()
        splitBackButtonNode = splitBackAction.map(makeSplitBackButtonNode)
        backButtonNode = showsBackButton ? makeBackButtonNode() : nil
        leadingItemsNode = leadingItems?.makeNode(navigationBarItemInputs())
        trailingItemsNode = trailingItems?.makeNode(navigationBarItemInputs())

        for node in childNodes {
            node.parent = self
            if let owner {
                node.updateViewOwner(owner)
            }
        }
        updateChildEnvironments()
    }

    private func makeTitleNode() -> ViewNode? {
        guard let title = configuration.title, !title.isEmpty else {
            return nil
        }
        let pointSize: Double = resolvedTitlePosition() == .leading ? 22 : 16
        let view = Text(title)
            .font(configuration.titleFont ?? .system(size: pointSize))
            .foregroundColor(.white)
            .lineLimit(1)
        let node = Text._makeView(_ViewGraphNode(value: view), inputs: inputs).node
        node.accessibilityIdentifier = "AdaUI.NavigationBar.Title"
        return node
    }

    private func makeSplitBackButtonNode(action: NavigationSplitCompactBackAction) -> ViewNode {
        let view = Button(action: {
            action.perform()
        }, label: {
            NavigationBackButtonIcon()
                .frame(width: Constants.controlHeight, height: Constants.controlHeight)
        })
        let node = Button._makeView(_ViewGraphNode(value: view), inputs: navigationBarItemInputs()).node
        node.accessibilityIdentifier = "AdaUI.NavigationSplitView.backButton"
        return node
    }

    private func makeBackButtonNode() -> ViewNode {
        let view = Button(action: { [weak navigationContext] in
            navigationContext?.pop()
        }, label: {
            NavigationBackButtonIcon()
                .frame(width: Constants.controlHeight, height: Constants.controlHeight)
        })
        return Button._makeView(_ViewGraphNode(value: view), inputs: navigationBarItemInputs()).node
    }

    private func navigationBarItemInputs() -> _ViewInputs {
        var styledInputs = inputs
        styledInputs.environment.buttonStyle = NavigationBarButtonStyle()
        return styledInputs
    }

    private func updateChildEnvironments() {
        titleNode?.updateEnvironment(inputs.environment)

        let itemEnvironment = navigationBarItemInputs().environment
        splitBackButtonNode?.updateEnvironment(itemEnvironment)
        backButtonNode?.updateEnvironment(itemEnvironment)
        leadingItemsNode?.updateEnvironment(itemEnvironment)
        trailingItemsNode?.updateEnvironment(itemEnvironment)
    }

    private func resolvedTitlePosition() -> NavigationTitlePosition {
        switch configuration.titlePosition {
        case .leading,
            .center:
            return configuration.titlePosition
        case .automatic:
            switch configuration.titleDisplayMode {
            case .large:
                return .leading
            case .automatic,
                .inline:
                return .center
            }
        }
    }
}
