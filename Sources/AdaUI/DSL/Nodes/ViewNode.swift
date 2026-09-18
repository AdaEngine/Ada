//
//  ViewNode.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 07.06.2024.
//

import AdaAnimation
import AdaInput
@_spi(Internal) import AdaUtils
import Logging
import Math
import Observation

@MainActor
enum UILayoutDebugCounters {
    struct Snapshot: Equatable {
        var contentInvalidations = 0
        var environmentInvalidations = 0
        var layoutInvalidations = 0
        var displayInvalidations = 0
        var rebuilds = 0
        var layoutPasses = 0
        var drawPasses = 0
        var sizeThatFitsCalls = 0
    }

    static var isEnabled = false
    private(set) static var snapshot = Snapshot()
    private(set) static var lastFrameSnapshot = Snapshot()

    static func reset() {
        snapshot = Snapshot()
        lastFrameSnapshot = Snapshot()
    }

    static func finishFrame() {
        guard isEnabled else {
            return
        }
        lastFrameSnapshot = snapshot
        snapshot = Snapshot()
    }

    static func recordContentInvalidation() {
        guard isEnabled else {
            return
        }
        snapshot.contentInvalidations += 1
    }

    static func recordEnvironmentInvalidation() {
        guard isEnabled else {
            return
        }
        snapshot.environmentInvalidations += 1
    }

    static func recordLayoutInvalidation() {
        guard isEnabled else {
            return
        }
        snapshot.layoutInvalidations += 1
    }

    static func recordDisplayInvalidation() {
        guard isEnabled else {
            return
        }
        snapshot.displayInvalidations += 1
    }

    static func recordRebuild() {
        guard isEnabled else {
            return
        }
        snapshot.rebuilds += 1
    }

    static func recordPerformLayout() {
        guard isEnabled else {
            return
        }
        snapshot.layoutPasses += 1
    }

    static func recordDrawPass() {
        guard isEnabled else {
            return
        }
        snapshot.drawPasses += 1
    }

    static func recordSizeThatFits() {
        guard isEnabled else {
            return
        }
        snapshot.sizeThatFitsCalls += 1
    }
}

// TODO: Add texture for drawing, to avoid rendering each time.

/// Build block for all system Views in AdaEngine.
/// Node represents a view that can be render, layout and interact.
@MainActor
class ViewNode: Identifiable {
    private static var inspectionRedrawRevisionCounter: UInt64 = 0
    private static var suppressedLayoutPropagationDepth = 0
    private static var layoutMutationRevision: UInt64 = 0

    nonisolated var id: ObjectIdentifier {
        ObjectIdentifier(self)
    }

    /// Contains ref to parent view
    private weak var _parent: ViewNode?
    var parent: ViewNode? {
        get {
            _parent
        }
        set {
            guard _parent !== newValue else {
                return
            }

            willMove(to: newValue)
            _parent = newValue
            didMove(to: _parent)
        }
    }

    /// View can be marked as notifiable about changes when called ``View/printChanges()`` method.
    private(set) var shouldNotifyAboutChanges: Bool

    /// Content relative a view node. We use this copy of content to compare views.
    private(set) var content: any View
    /// Structural identity component supplied by result-builder constructs that
    /// are not represented by a concrete node in the rendered tree.
    var structuralIdentity: AnyHashable?

    var layer: UILayer?
    private(set) weak var owner: ViewOwner?
    /// hold storages that can invalidate that view node.
    var storages: WeakSet<UpdatablePropertyStorage> = []
    var stateContainer: ViewStateContainer?

    private var isAttached: Bool {
        return owner != nil
    }

    var accessibilityIdentifier: String?

    /// Contains current environment values (post-transform).
    private(set) var environment = EnvironmentValues()

    /// Optional transform applied on top of the parent environment.
    /// Set by `.environment()` / `.transformEnvironment()` modifiers via `_ViewInputs.pendingEnvironmentTransform`.
    /// Allows lazy re-derivation when the parent environment changes.
    var environmentTransform: ((inout EnvironmentValues) -> Void)?

    /// Contains position and size relative to parent view.
    private(set) var frame: Rect = .zero
    private(set) var lastLayoutProposal: ProposedViewSize = .unspecified
    var transform: Transform3D = .identity
    private(set) var layoutProperties = LayoutProperties()
    private var isPerformingAnimatedLayout = false
    private var needsLayoutPass = true
    private var inspectionRedrawRevision: UInt64 = 0

    var layoutPriority: Double {
        0
    }

    var participatesInFrameAnimation: Bool {
        true
    }

    var allowsNestedFrameAnimation: Bool {
        false
    }

    init<Content: View>(content: Content) {
        self.content = content
        self.shouldNotifyAboutChanges = ViewGraph.shouldNotifyAboutChanges(Content.self)
    }

    /// Search view recursevly by id. It usable only for ``IDViewNodeModifier``.
    func findNodeById(_: AnyHashable) -> ViewNode? {
        return nil
    }

    func findNodyByAccessibilityIdentifier(_ identifier: String) -> ViewNode? {
        return identifier == self.accessibilityIdentifier ? self : nil
    }

    /// Set a new content for view node.
    /// - Note: This method don't call ``invalidateContent()`` method
    func setContent<Content: View>(_ content: Content) {
        self.content = content
        self.shouldNotifyAboutChanges = ViewGraph.shouldNotifyAboutChanges(type(of: content))
        self.markNeedsLayout()
    }

    /// Returns true if the node clips its children to its bounds.
    open var isClipping: Bool {
        return false
    }

    /// Calculates the visible frame of the node by intersecting it with all clipping parents.
    public func calculateVisibleFrame() -> Rect {
        var visibleFrame = self.visualAbsoluteFrame()
        var currentParent = self.parent

        while let parent = currentParent {
            if parent.isClipping {
                let parentFrame = parent.visualAbsoluteFrame()
                visibleFrame = visibleFrame.intersection(parentFrame)
            }
            currentParent = parent.parent
        }

        return visibleFrame
    }

    // MARK: - Layout

    func updatePreference<K: PreferenceKey>(key _: K.Type, value: K.Value) {
        self.parent?.updatePreference(key: K.self, value: value)
    }

    /// Updates stored environment.
    /// Applies any stored `environmentTransform` on top of the incoming parent environment,
    /// then short-circuits via the version guard if nothing actually changed.
    /// For storages with known key subscriptions, only triggers a rebuild when a subscribed key value changed.
    func updateEnvironment(_ parentEnvironment: EnvironmentValues) {
        var env = parentEnvironment
        environmentTransform?(&env)
        env.viewProxy = ViewProxy(target: self)
        let previousEnvironment = self.environment
        let didChangeEnvironment = !env.hasSameSnapshot(as: previousEnvironment)
        guard didChangeEnvironment else {
            return
        }
        UILayoutDebugCounters.recordEnvironmentInvalidation()
        env.ensureVersionDiffers(from: previousEnvironment.version)
        self.environment = env
        self.markNeedsLayout(propagateToParent: false)
        var shouldInvalidateForEnvironmentChange = false
        storages.forEach { storage in
            guard let viewContextStorage = storage as? ViewContextStorage else {
                return
            }
            let subscribedKeyIDs = viewContextStorage.subscribedKeyIDs
            // Compare subscribed key values between the storage's last-seen env and the new env.
            // If subscription set is empty the storage subscribes to everything.
            guard
                subscribedKeyIDs.isEmpty
                    || self.environment.hasChangedValues(forKeyIDs: subscribedKeyIDs, comparedTo: viewContextStorage.values)
            else {
                // Subscribed keys unchanged — skip rebuild but keep values in sync.
                viewContextStorage.values = self.environment
                return
            }
            viewContextStorage.values = self.environment
            shouldInvalidateForEnvironmentChange = true
        }

        if shouldInvalidateForEnvironmentChange {
            self.invalidateContent()
            owner?.containerView?.setNeedsLayout()
        }
    }

    /// Stores an already-resolved environment and syncs VCS values without triggering re-renders.
    /// Used during reconciliation (update(from:)) where `newNode.environment` already contains
    /// all inherited and transformed values.
    func applyResolvedEnvironmentSilently(_ environment: EnvironmentValues) {
        let previousEnvironment = self.environment
        var environment = environment
        environment.viewProxy = ViewProxy(target: self)
        let didChangeEnvironment = !environment.hasSameSnapshot(as: previousEnvironment)
        if didChangeEnvironment {
            environment.ensureVersionDiffers(from: previousEnvironment.version)
        }
        self.environment = environment
        if didChangeEnvironment {
            self.markNeedsLayout(propagateToParent: false)
        }
        storages.forEach { storage in
            guard let viewContextStorage = storage as? ViewContextStorage else {
                return
            }
            viewContextStorage.values = self.environment
        }
    }

    var transientEnvironmentChildren: [ViewNode] {
        []
    }

    func performWithTransientAnimationController(_ animationController: UIAnimationController, _ operation: () -> Void) {
        let originalEnvironment = self.environment
        var animatedEnvironment = originalEnvironment
        animatedEnvironment.animationController = animationController

        applyTransientEnvironmentTree(animatedEnvironment)
        operation()
        applyTransientEnvironmentTree(originalEnvironment)
    }

    private func applyTransientEnvironmentTree(_ resolvedEnvironment: EnvironmentValues) {
        applyResolvedEnvironmentSilently(resolvedEnvironment)

        for child in transientEnvironmentChildren {
            var childEnvironment = resolvedEnvironment
            child.environmentTransform?(&childEnvironment)
            child.applyTransientEnvironmentTree(childEnvironment)
        }
    }

    /// Merges partial environment values into the current environment.
    /// Use this for external updates that don't carry the full environment snapshot.
    func mergeEnvironment(_ environment: EnvironmentValues) {
        var mergedEnvironment = self.environment
        mergedEnvironment.merge(environment)
        self.updateEnvironment(mergedEnvironment)
    }

    /// Update layout properties for view.
    /// Called each time, when parent container view did change layout direction.
    func updateLayoutProperties(_ props: LayoutProperties) {
        guard self.layoutProperties != props else {
            return
        }
        self.layoutProperties = props
        self.markNeedsLayout()
    }

    /// Returns size for view node in measuring cycle.
    /// Parent view proposal sizes and views should calculate theirs sizes for given constraints.
    func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        UILayoutDebugCounters.recordSizeThatFits()
        return proposal.replacingUnspecifiedDimensions()
    }

    /// Place view in specific point and anchor.
    /// After placement, automatically call ``performLayout()`` method.
    func place(in origin: Point, anchor: AnchorPoint, proposal: ProposedViewSize) {
        let size = self.sizeThatFits(proposal)
        self.place(in: origin, anchor: anchor, proposal: proposal, measuredSize: size)
    }

    func place(in origin: Point, anchor: AnchorPoint, proposal: ProposedViewSize, measuredSize size: Size) {
        self.lastLayoutProposal = proposal
        let offset = Point(
            x: origin.x - size.width * anchor.x,
            y: origin.y - size.height * anchor.y
        )

        let newFrame = Rect(origin: offset, size: size)
        let oldFrame = self.frame
        let shouldPerformLayout = oldFrame != newFrame || needsLayoutPass
        let isNestedAnimatedLayout = isInsideAnimatedLayoutPass()
        let canAnimateInNestedLayout = canAnimateNestedFrameChange(from: oldFrame, to: newFrame)

        if participatesInFrameAnimation,
            let animationController = self.environment.animationController,
            self.frame != .zero,
            oldFrame != newFrame,
            !isNestedAnimatedLayout || canAnimateInNestedLayout {
            animationController.addTweenAnimation(
                from: self.frame,
                to: newFrame,
                label: "frame-\(self.id)",
                environment: self.environment,
                updateBlock: { [weak self] value in
                    guard let self else {
                        return
                    }
                    let previousFrame = self.frame
                    self.frame = value
                    self.isPerformingAnimatedLayout = true
                    UILayoutDebugCounters.recordPerformLayout()
                    self.performLayout()
                    self.markLayoutClean()
                    self.isPerformingAnimatedLayout = false
                    if previousFrame.size != value.size {
                        self.parent?.performAnimatedLayoutPass()
                    }
                    self.invalidateNearestLayer()
                }
            )
        } else {
            self.frame = newFrame
            if shouldPerformLayout {
                UILayoutDebugCounters.recordPerformLayout()
                self.performLayout()
                self.markLayoutClean()
            }
        }

        if oldFrame != newFrame, let containerView = self.owner?.containerView {
            let oldAbsolute = absoluteFrame(using: oldFrame)
            let newAbsolute = absoluteFrame(using: newFrame)
            containerView.setNeedsDisplay(in: oldAbsolute.union(newAbsolute))
        }
    }

    /// Updates view layout. Called when needs update UI layout.
    func performLayout() {
        invalidateLayerIfNeeded()
    }

    func performAnimatedLayoutPass() {
        let wasPerformingAnimatedLayout = isPerformingAnimatedLayout
        isPerformingAnimatedLayout = true
        UILayoutDebugCounters.recordPerformLayout()
        performLayout()
        markLayoutClean()
        isPerformingAnimatedLayout = wasPerformingAnimatedLayout
    }

    func isInsideAnimatedLayoutPass() -> Bool {
        var currentParent = parent
        while let parent = currentParent {
            if parent.isPerformingAnimatedLayout {
                return true
            }
            currentParent = parent.parent
        }
        return false
    }

    func canAnimateNestedFrameChange(from oldFrame: Rect, to newFrame: Rect) -> Bool {
        allowsNestedFrameAnimation && oldFrame.size != newFrame.size
    }

    func nearestAnimationController() -> UIAnimationController? {
        var current: ViewNode? = self
        while let node = current {
            if let provider = node as? _AnimationControllerProvider,
                let animationController = provider.providedAnimationController {
                return animationController
            }
            current = node.parent
        }
        return nil
    }

    func canUpdate(_ node: ViewNode) -> Bool {
        return self.isEquals(node)
            && self.id != node.id
            && self.structuralIdentity == node.structuralIdentity
    }

    func isEquals(_ otherNode: ViewNode) -> Bool {
        // Compare content of POD or Equals
        if _ViewGraphNode(value: self.content) == _ViewGraphNode(value: otherNode.content) {
            return true
        }

        /// Check that runtime type is equals.
        return type(of: otherNode.content) == type(of: self.content)
    }

    /// Update current node with a new. This method called after ``invalidationContent()`` method
    /// and if view exists in tree, we should update exsiting view using ``ViewNode/update(_:)`` method.
    var uiSceneNodeID: String?

    func update(from newNode: ViewNode) {
        self.markInspectionRedraw()
        let shouldInvalidateForEnvironmentChange = shouldInvalidateContent(forResolvedEnvironment: newNode.environment)
        self.environmentTransform = newNode.environmentTransform
        self.structuralIdentity = newNode.structuralIdentity
        self.accessibilityIdentifier = newNode.accessibilityIdentifier
        self.uiSceneNodeID = newNode.uiSceneNodeID
        var resolvedEnvironment = newNode.environment
        if !resolvedEnvironment.animationsDisabled,
            resolvedEnvironment.animationController == nil,
            let animationController = self.environment.animationController {
            resolvedEnvironment.animationController = animationController
        }
        self.applyResolvedEnvironmentSilently(resolvedEnvironment)
        self.setContent(newNode.content)
        self.rebindStorages()
        if shouldInvalidateForEnvironmentChange {
            self.invalidateContent()
            owner?.containerView?.setNeedsLayout()
        }
    }

    private func shouldInvalidateContent(forResolvedEnvironment environment: EnvironmentValues) -> Bool {
        storages.contains { storage in
            guard let viewContextStorage = storage as? ViewContextStorage else {
                return false
            }
            let subscribedKeyIDs = viewContextStorage.subscribedKeyIDs
            return subscribedKeyIDs.isEmpty
                || environment.hasChangedValues(forKeyIDs: subscribedKeyIDs, comparedTo: viewContextStorage.values)
        }
    }

    private func rebindStorages() {
        var inputs = _ViewInputs(parentNode: self.parent, environment: self.environment)
        inputs = inputs.resolveStorages(in: self.content, stateContainer: self.stateContainer)
        self.storages = []
        inputs.registerNodeForStorages(self)
    }

    /// This method invalidate all stored views and create a new one.
    func invalidateContent() {}

    /// Invalidates content while suppressing redundant propagation during reconciliation.
    /// Once the subtree has been rebuilt, layout dirtiness still bubbles to the root because
    /// a changed intrinsic size can reposition siblings in an ancestor layout container.
    func invalidateContent(propagateLayout: Bool) {
        guard !propagateLayout else {
            self.invalidateContent()
            return
        }

        Self.withSuppressedLayoutPropagation {
            self.invalidateContent()
        }
        self.markNeedsLayout()
        self.invalidateNearestLayer()
        owner?.containerView?.setNeedsLayout(in: visualAbsoluteFrame())
    }

    func markNeedsLayout(propagateToParent: Bool = true) {
        UILayoutDebugCounters.recordLayoutInvalidation()
        let shouldPropagate = propagateToParent && Self.suppressedLayoutPropagationDepth == 0
        guard !needsLayoutPass else {
            if shouldPropagate {
                parent?.markNeedsLayout()
            }
            return
        }

        needsLayoutPass = true
        if shouldPropagate {
            parent?.markNeedsLayout()
        }
    }

    func markLayoutClean() {
        needsLayoutPass = false
    }

    func invalidateNearestLayer() {
        var current: ViewNode? = self
        while let node = current {
            if let layer = node.layer {
                layer.invalidate()
                return
            }
            current = node.parent
        }
    }

    func invalidateLayerIfNeeded() {
        if let layer = self.layer {
            if layer.frame.size != self.frame.size {
                layer.setFrame(self.frame)
            }

            layer.invalidate()
        } else if self.isAttached {
            self.layer = self.createLayer()
            self.layer?.parent = self.parent?.layer
        }
    }

    func createLayer() -> UILayer? { return nil }

    static func currentInspectionRedrawRevision() -> UInt64 {
        inspectionRedrawRevisionCounter
    }

    func markInspectionRedraw() {
        Self.inspectionRedrawRevisionCounter += 1
        self.inspectionRedrawRevision = Self.inspectionRedrawRevisionCounter

        if owner?.isInspectionRedrawOverlayEnabled == true {
            owner?.containerView?.setNeedsDisplay(in: visualAbsoluteFrame())
        }
    }

    func absoluteFrame() -> Rect {
        return absoluteFrame(using: self.frame)
    }

    func absoluteFrame(using localFrame: Rect) -> Rect {
        var origin = localFrame.origin
        var currentParent = self.parent
        while let parent = currentParent {
            origin += parent.frame.origin
            currentParent = parent.parent
        }
        return Rect(origin: origin, size: localFrame.size)
    }

    /// Returns the node frame in root coordinates after applying ancestor scroll offsets.
    func visualAbsoluteFrame() -> Rect {
        return visualAbsoluteFrame(using: self.frame)
    }

    func visualAbsoluteFrame(using localFrame: Rect) -> Rect {
        var origin = localFrame.origin
        var currentParent = self.parent

        while let parent = currentParent {
            origin += parent.frame.origin
            if let scrollNode = parent as? ScrollViewNode {
                origin.x -= scrollNode.contentOffset.x
                origin.y -= scrollNode.contentOffset.y
            }
            currentParent = parent.parent
        }

        return Rect(origin: origin, size: localFrame.size)
    }

    /// Notify view, that view will move to parent view.
    func willMove(to _: ViewNode?) {}

    /// Notify view, that view did move to parent view.
    func didMove(to parent: ViewNode?) {
        layer?.parent = parent?.layer
    }

    func updateViewOwner(_ owner: ViewOwner) {
        self.owner = owner
    }

    func buildMenu(with _: UIMenuBuilder) {}

    // MARK: - Other

    func update(_: TimeInterval) {}

    /// Perform draw view on the screen.
    func draw(with context: UIGraphicsContext) {
        var context = context
        context.translateBy(x: self.frame.origin.x, y: -self.frame.origin.y)

        if let layer {
            layer.drawLayer(in: context)
        }
    }

    func drawInspectionDebugOverlay(
        with context: UIGraphicsContext,
        mode: UIDebugOverlayMode,
        redrawBaselineRevision: UInt64,
        focusedNode: ViewNode?,
        hitTestNode: ViewNode?
    ) {
        if mode == .redraw {
            drawInspectionRedrawFlashes(
                with: context,
                baselineRevision: redrawBaselineRevision
            )
            return
        }

        drawInspectionLayoutBounds(with: context)
        drawInspectionSelectionBounds(
            with: context,
            mode: mode,
            focusedNode: focusedNode,
            hitTestNode: hitTestNode
        )
    }

    func drawInspectionRedrawFlashes(
        with context: UIGraphicsContext,
        baselineRevision: UInt64
    ) {
        let context = inspectionLocalContext(from: context)
        drawInspectionRedrawFlashIfNeeded(
            with: context,
            baselineRevision: baselineRevision
        )
        drawInspectionChildRedrawFlashes(
            with: context,
            baselineRevision: baselineRevision
        )
    }

    func drawInspectionLayoutBounds(with context: UIGraphicsContext) {
        let context = inspectionLocalContext(from: context)
        drawInspectionLayoutBorder(with: context)
        drawInspectionChildLayoutBounds(with: context)
    }

    func drawInspectionSelectionBounds(
        with context: UIGraphicsContext,
        mode: UIDebugOverlayMode,
        focusedNode: ViewNode?,
        hitTestNode: ViewNode?
    ) {
        let context = inspectionLocalContext(from: context)
        drawInspectionSelectionBorderIfNeeded(
            with: context,
            mode: mode,
            focusedNode: focusedNode,
            hitTestNode: hitTestNode
        )
        drawInspectionChildSelectionBounds(
            with: context,
            mode: mode,
            focusedNode: focusedNode,
            hitTestNode: hitTestNode
        )
    }

    func drawInspectionChildLayoutBounds(with _: UIGraphicsContext) {}

    func drawInspectionChildRedrawFlashes(
        with _: UIGraphicsContext,
        baselineRevision _: UInt64
    ) {}

    func drawInspectionChildSelectionBounds(
        with _: UIGraphicsContext,
        mode _: UIDebugOverlayMode,
        focusedNode _: ViewNode?,
        hitTestNode _: ViewNode?
    ) {}

    func inspectionLocalContext(from context: UIGraphicsContext) -> UIGraphicsContext {
        var context = context
        context.environment = environment
        context.translateBy(x: self.frame.origin.x, y: -self.frame.origin.y)
        return context
    }

    func drawInspectionLayoutBorder(with context: UIGraphicsContext) {
        drawInspectionBounds(
            with: context,
            lineWidth: 1,
            color: Self.inspectionLayoutBoundsColor
        )
    }

    func drawInspectionSelectionBorderIfNeeded(
        with context: UIGraphicsContext,
        mode: UIDebugOverlayMode,
        focusedNode: ViewNode?,
        hitTestNode: ViewNode?
    ) {
        switch mode {
        case .focusedNode where self === focusedNode:
            drawInspectionBounds(
                with: context,
                lineWidth: 3,
                color: Self.inspectionFocusedNodeColor,
                fillColor: Self.inspectionFocusedNodeFillColor
            )
        case .hitTestTarget where self === hitTestNode:
            drawInspectionBounds(
                with: context,
                lineWidth: 3,
                color: Self.inspectionHitTestTargetColor,
                fillColor: Self.inspectionHitTestTargetFillColor
            )
        default:
            break
        }
    }

    func drawInspectionRedrawFlashIfNeeded(
        with context: UIGraphicsContext,
        baselineRevision: UInt64
    ) {
        guard inspectionRedrawRevision > baselineRevision else {
            return
        }

        context.drawRect(
            Rect(origin: .zero, size: frame.size),
            color: Self.inspectionRedrawFillColor
        )
        context.drawDebugBorders(
            frame.size,
            lineWidth: 2,
            color: Self.inspectionRedrawBorderColor
        )
        inspectionRedrawRevision = 0
        owner?.containerView?.setNeedsDisplay(in: visualAbsoluteFrame())
    }

    func drawInspectionBounds(
        with context: UIGraphicsContext,
        lineWidth: Float,
        color: Color,
        fillColor: Color? = nil
    ) {
        if let fillColor {
            context.drawRect(Rect(origin: .zero, size: frame.size), color: fillColor)
        }

        context.drawDebugBorders(frame.size, lineWidth: lineWidth, color: color)
    }

    // MARK: - Interaction

    func onReceiveEvent(_: any InputEvent) {}

    func hitTest(_: Point, with _: any InputEvent) -> ViewNode? {
        // Non-interactive by default.
        // Interactive nodes must override this method explicitly.
        return nil
    }

    /// - Returns: true if point is inside the receiver’s bounds; otherwise, false.
    func point(inside point: Point, with _: any InputEvent) -> Bool {
        return point.x >= 0 && point.y >= 0 && point.x <= frame.width && point.y <= frame.height
    }

    func convert(_ point: Point, to node: ViewNode?) -> Point {
        guard let node, node !== self else {
            return point
        }

        if node.parent === self {
            return point - node.frame.origin
        } else if let parent = self.parent, parent === node {
            return point + frame.origin
        }

        return point
    }

    func convert(_ point: Point, from node: ViewNode?) -> Point {
        return node?.convert(point, to: self) ?? point
    }

    func onPinchEvent(_: PinchEvent) {}

    func onTouchesEvent(_: Set<TouchEvent>) {}

    func onMouseEvent(_: MouseEvent) {}

    var canBecomeFocused: Bool {
        false
    }

    func onFocusChanged(isFocused _: Bool) {}

    func onKeyEvent(_: KeyEvent) {}

    func onTextInputEvent(_: TextInputEvent) {}

    func onMouseLeave() {}

    func findFirstResponder(for event: any InputEvent) -> ViewNode? {
        let responder: ViewNode?

        switch event {
        case let event as MouseEvent:
            let point = event.mousePosition
            responder = self.hitTest(point, with: event)
        case let event as TouchEvent:
            let point = event.location
            responder = self.hitTest(point, with: event)
        default:
            return nil
        }

        return responder
    }

    // MARK: - Debug

    func _printDebugNode() {
        Logger(label: "org.adaengine.AdaUI").error("\(self.debugDescription(hierarchy: 0))")
    }

    func debugDescription(hierarchy: Int = 0, identation: Int = 2) -> String {
        let identation = String(repeating: " ", count: hierarchy * identation)
        return """
            \(identation)>\(type(of: self)):
            \(identation) > frame: \(frame)
            \(identation) > content: \(type(of: self.content))
            """
    }
}

extension ViewNode {
    static var currentLayoutMutationRevision: UInt64 {
        layoutMutationRevision
    }

    static func recordLayoutMutationRequiringAncestorPass() {
        layoutMutationRevision &+= 1
    }

    static var isLayoutPropagationSuppressed: Bool {
        suppressedLayoutPropagationDepth > 0
    }

    static func withSuppressedLayoutPropagation(_ operation: () -> Void) {
        suppressedLayoutPropagationDepth += 1
        defer { suppressedLayoutPropagationDepth -= 1 }
        operation()
    }
}

extension ViewNode: @preconcurrency Hashable {
    static func == (lhs: ViewNode, rhs: ViewNode) -> Bool {
        return lhs.isEquals(rhs)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.id)
    }
}

@MainActor
protocol ViewOwner: AnyObject {
    var window: UIWindow? { get }

    var containerView: UIView? { get }

    var isInspectionRedrawOverlayEnabled: Bool { get }

    func updateEnvironment(_ env: EnvironmentValues)

    func addTransientAnimationController(_ animationController: UIAnimationController)

    func enqueueLifecycleAction(_ action: @escaping @MainActor () -> Void)
}

extension UIGraphicsContext {
    func drawDebugBorders(_ size: Size, lineWidth: Float = 1, color: Color = .random()) {
        self.drawLine(start: Vector2(0, 0), end: Vector2(size.width, 0), lineWidth: lineWidth, color: color)
        self.drawLine(start: Vector2(0, 0), end: Vector2(0, -size.height), lineWidth: lineWidth, color: color)
        self.drawLine(start: Vector2(size.width, 0), end: Vector2(size.width, -size.height), lineWidth: lineWidth, color: color)
        self.drawLine(start: Vector2(0, -size.height), end: Vector2(size.width, -size.height), lineWidth: lineWidth, color: color)
    }
}

extension ViewNode {
    private static let inspectionLayoutBoundsColor = Color.fromHex(0x00D9FF).opacity(0.72)
    private static let inspectionFocusedNodeColor = Color.fromHex(0x2D7EFF)
    private static let inspectionFocusedNodeFillColor = Color.fromHex(0x2D7EFF).opacity(0.12)
    private static let inspectionHitTestTargetColor = Color.fromHex(0xFF2D55)
    private static let inspectionHitTestTargetFillColor = Color.fromHex(0xFF2D55).opacity(0.12)
    private static let inspectionRedrawBorderColor = Color.fromHex(0xFF2D55).opacity(0.92)
    private static let inspectionRedrawFillColor = Color.fromHex(0xFF2D55).opacity(0.26)
}
