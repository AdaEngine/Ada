//
//  ScrollView.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 24.06.2024.
//

import AdaInput
import AdaUtils
import Math

/// A scrollable view.
@MainActor @preconcurrency
public struct ScrollView<Content: View>: View, ViewNodeBuilder {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    let axis: Axis
    let showsIndicators: Bool
    let content: () -> Content

    /// Creates a scroll view, optionally showing viewport indicators when content overflows.
    public init(
        _ axis: Axis = .vertical,
        showsIndicators: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.axis = axis
        self.showsIndicators = showsIndicators
        self.content = content
    }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let node = ScrollViewNode(layout: ZStackLayout(anchor: .topLeading), content: content)
        node.axis = self.axis
        node.showsIndicators = self.showsIndicators
        node.updateEnvironment(context.environment)
        context.environment.scrollViewProxy?.subsribe(node)
        node.invalidateContent()

        return node
    }
}

// FIXME: Hit test doesn't work correctly on bottom

final class ScrollViewNode: LayoutViewContainerNode {
    var axis: Axis = .vertical
    var showsIndicators = false

    override func update(from newNode: ViewNode) {
        super.update(from: newNode)
        guard let scroll = newNode as? ScrollViewNode else {
            return
        }
        axis = scroll.axis
        showsIndicators = scroll.showsIndicators
    }

    override var isClipping: Bool {
        return true
    }

    private(set) var contentOffset: Point = .zero
    private var contentSize: Size = .zero

    override func performLayout() {
        let viewportSize = self.frame.size
        let contentInsets = resolvedContentInsets()
        let proposedWidth: Float? = axis.contains(.horizontal) ? nil : viewportSize.width
        let proposedHeight: Float? = axis.contains(.vertical) ? nil : viewportSize.height
        let proposal = ProposedViewSize(width: proposedWidth, height: proposedHeight)
        let measuredContentSize = super.sizeThatFits(proposal)

        let measuredWidth = measuredContentSize.width.isFinite ? measuredContentSize.width : viewportSize.width
        let measuredHeight = measuredContentSize.height.isFinite ? measuredContentSize.height : viewportSize.height

        let insetWidth = contentInsets.leading + contentInsets.trailing
        let insetHeight = contentInsets.top + contentInsets.bottom
        let contentWidth = axis.contains(.horizontal) ? max(measuredWidth + insetWidth, viewportSize.width) : viewportSize.width
        let contentHeight = axis.contains(.vertical) ? max(measuredHeight + insetHeight, viewportSize.height) : viewportSize.height
        self.contentSize = Size(width: contentWidth, height: contentHeight)

        let width = max(0, contentSize.width - viewportSize.width)
        let height = max(0, contentSize.height - viewportSize.height)
        self.contentOffsetBounds = Rect(x: 0, y: 0, width: width, height: height)
        if case .idle = state {
            self.contentOffset = clampOffset(self.contentOffset)
        }

        let contentOrigin = Point(
            x: crossAxisOrigin(
                scrollsOnAxis: axis.contains(.horizontal),
                measured: measuredWidth,
                viewport: viewportSize.width
            ),
            y: crossAxisOrigin(
                scrollsOnAxis: axis.contains(.vertical),
                measured: measuredHeight,
                viewport: viewportSize.height
            )
        )

        let insetContentSize = Size(
            width: max(0, contentSize.width - insetWidth),
            height: max(0, contentSize.height - insetHeight)
        )

        super
            .performLayout(
                in: Rect(
                    origin: Point(
                        x: contentOrigin.x + contentInsets.leading,
                        y: contentOrigin.y + contentInsets.top
                    ),
                    size: insetContentSize
                ),
                proposal: ProposedViewSize(insetContentSize)
            )
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event) else {
            return nil
        }

        if let mouseEvent = event as? MouseEvent, mouseEvent.button == .scrollWheel {
            return self
        }

        let contentPoint = Point(
            x: point.x + contentOffset.x,
            y: point.y + contentOffset.y
        )

        if let childHit = super.hitTest(contentPoint, with: event) {
            return childHit
        }

        // For touch events, claim the hit ourselves so drag-to-scroll works
        if event is TouchEvent {
            return self
        }

        return nil
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        if proposal == .zero {
            return .zero
        }

        let proposedWidth = finiteDimension(proposal.width)
        let proposedHeight = finiteDimension(proposal.height)
        let contentProposal = ProposedViewSize(
            width: axis.contains(.horizontal) ? nil : proposedWidth,
            height: axis.contains(.vertical) ? nil : proposedHeight
        )
        let measuredContentSize = super.sizeThatFits(contentProposal)

        let width = resolvedDimension(
            proposed: proposal.width,
            measured: measuredContentSize.width,
            isScrollAxis: axis.contains(.horizontal)
        )
        let height = resolvedDimension(
            proposed: proposal.height,
            measured: measuredContentSize.height,
            isScrollAxis: axis.contains(.vertical)
        )

        return Size(width: max(0, width), height: max(0, height))
    }

    enum State {
        case idle
        case dragging(initialOffset: Point)
        case animating
    }

    private var accumulativePoint: Point = .zero
    private var state: State = .idle
    private var velocity: Point = .zero
    private var velocityTracker: [(time: TimeInterval, position: Point)] = []
    private var timeSinceLastScroll: Float = 0

    static let decelerationFriction: Float = 1.0
    static let scrollTimeout: Float = 0.05
    static let springStiffness: Float = 400
    static let springDamping: Float = 40
    static let rubberBandCoefficient: Float = 0.02
    static let animationThreshold: Float = 0.5

    private var lastScrollEvent: TimeInterval?
    private var wheelInteractionUsesExplicitPhases = false

    override func onMouseEvent(_ event: MouseEvent) {
        guard event.button == .scrollWheel else {
            return
        }

        switch event.phase {
        case .began:
            beginWheelInteraction(explicitPhases: true)
            recordWheelEvent(at: event.time)
            applyWheelDelta(event.scrollDelta)
        case .changed:
            if !isWheelInteractionActive {
                beginWheelInteraction(explicitPhases: false)
            }
            recordWheelEvent(at: event.time)
            applyWheelDelta(event.scrollDelta)
        case .ended,
            .cancelled:
            finishWheelInteraction()
        }
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        guard let touch = touches.first else {
            return
        }

        switch touch.phase {
        case .began:
            velocity = .zero
            lastScrollEvent = nil
            timeSinceLastScroll = 0
            accumulativePoint = .zero
            velocityTracker = []
            state = .dragging(initialOffset: self.contentOffset)
        case .moved:
            guard case let .dragging(initialOffset) = state else {
                return
            }
            accumulativePoint.x += touch.location.x - (lastTouchLocation?.x ?? touch.location.x)
            accumulativePoint.y += touch.location.y - (lastTouchLocation?.y ?? touch.location.y)
            let rawOffset = Point(
                x: initialOffset.x - accumulativePoint.x,
                y: initialOffset.y - accumulativePoint.y
            )
            setContentOffset(rubberBandOffset(rawOffset))

            velocityTracker.append((time: touch.time, position: touch.location))
            if velocityTracker.count > 5 {
                velocityTracker.removeFirst()
            }
        case .ended,
            .cancelled:
            let releaseVelocity = calculateReleaseVelocity()
            let overscroll = calculateOverscroll(contentOffset)

            if overscroll != .zero || (releaseVelocity.x * releaseVelocity.x + releaseVelocity.y * releaseVelocity.y) > 1 {
                velocity = releaseVelocity
                state = .animating
            } else {
                state = .idle
            }

            accumulativePoint = .zero
            velocityTracker = []
        }

        lastTouchLocation = touch.location
        if touch.phase == .ended || touch.phase == .cancelled {
            lastTouchLocation = nil
        }
    }

    private var lastTouchLocation: Point?

    // MARK: - Bounce Animation

    override func update(_ deltaTime: TimeInterval) {
        super.update(deltaTime)

        if !wheelInteractionUsesExplicitPhases, lastScrollEvent != nil, case .dragging = state {
            timeSinceLastScroll += deltaTime
            if timeSinceLastScroll >= Self.scrollTimeout {
                finishWheelInteraction()
            }
        }

        guard case .animating = state, deltaTime > 0 else {
            return
        }

        var newOffset = contentOffset
        var finished = true

        if axis.contains(.vertical) {
            if !updateBounceAxis(
                offset: &newOffset.y,
                velocity: &velocity.y,
                minBound: contentOffsetBounds.minY,
                maxBound: contentOffsetBounds.maxY,
                dimension: frame.size.height,
                dt: deltaTime
            ) {
                finished = false
            }
        }

        if axis.contains(.horizontal) {
            if !updateBounceAxis(
                offset: &newOffset.x,
                velocity: &velocity.x,
                minBound: contentOffsetBounds.minX,
                maxBound: contentOffsetBounds.maxX,
                dimension: frame.size.width,
                dt: deltaTime
            ) {
                finished = false
            }
        }

        setContentOffset(newOffset)

        if finished {
            setContentOffset(clampOffset(contentOffset))
            velocity = .zero
            state = .idle
        }
    }

    private func updateBounceAxis(
        offset: inout Float,
        velocity: inout Float,
        minBound: Float,
        maxBound: Float,
        dimension _: Float,
        dt: Float
    ) -> Bool {
        let overscroll: Float
        if offset < minBound {
            overscroll = offset - minBound
        } else if offset > maxBound {
            overscroll = offset - maxBound
        } else {
            overscroll = 0
        }
        let startedBelowBounds = offset < minBound
        let startedAboveBounds = offset > maxBound

        if overscroll != 0 {
            let springForce = -Self.springStiffness * overscroll
            let dampingForce = -Self.springDamping * velocity
            velocity += (springForce + dampingForce) * dt
        } else {
            velocity *= max(0, 1 - Self.decelerationFriction * dt)
        }

        offset += velocity * dt

        if startedBelowBounds && offset >= minBound {
            offset = minBound
            velocity = .zero
            return true
        }

        if startedAboveBounds && offset <= maxBound {
            offset = maxBound
            velocity = .zero
            return true
        }

        if overscroll == 0 {
            if offset < minBound {
                offset = minBound
                velocity = .zero
                return true
            }
            if offset > maxBound {
                offset = maxBound
                velocity = .zero
                return true
            }
        }

        let currentOverscroll: Float
        if offset < minBound {
            currentOverscroll = minBound - offset
        } else if offset > maxBound {
            currentOverscroll = offset - maxBound
        } else {
            currentOverscroll = 0
        }

        return abs(velocity) < Self.animationThreshold && currentOverscroll < Self.animationThreshold
    }

    private var isWheelInteractionActive: Bool {
        if case .dragging = state {
            return true
        }

        return false
    }

    private func beginWheelInteraction(explicitPhases: Bool) {
        accumulativePoint = .zero
        velocity = .zero
        timeSinceLastScroll = 0
        lastScrollEvent = nil
        wheelInteractionUsesExplicitPhases = explicitPhases
        state = .dragging(initialOffset: self.contentOffset)
    }

    private func recordWheelEvent(at time: TimeInterval) {
        timeSinceLastScroll = 0
        lastScrollEvent = time
    }

    private func applyWheelDelta(_ delta: Point) {
        guard case let .dragging(initialOffset) = state else {
            return
        }

        accumulativePoint.x += delta.x * 100
        accumulativePoint.y += delta.y * 100
        setContentOffset(rubberBandOffset(initialOffset - accumulativePoint))
    }

    private func finishWheelInteraction() {
        lastScrollEvent = nil
        timeSinceLastScroll = 0
        accumulativePoint = .zero
        wheelInteractionUsesExplicitPhases = false

        if calculateOverscroll(contentOffset) != .zero {
            velocity = .zero
            state = .animating
        } else if case .dragging = state {
            state = .idle
        }
    }

    // MARK: - Rubber Band

    private func rubberBandOffset(_ offset: Point) -> Point {
        var result = contentOffset
        if axis.contains(.vertical) {
            result.y = rubberBandClamp(
                offset.y,
                min: contentOffsetBounds.minY,
                max: contentOffsetBounds.maxY,
                dimension: frame.size.height
            )
        }
        if axis.contains(.horizontal) {
            result.x = rubberBandClamp(
                offset.x,
                min: contentOffsetBounds.minX,
                max: contentOffsetBounds.maxX,
                dimension: frame.size.width
            )
        }
        return result
    }

    private func rubberBandClamp(_ value: Float, min minBound: Float, max maxBound: Float, dimension: Float) -> Float {
        if value < minBound {
            return minBound - rubberBandDistance(minBound - value, dimension: dimension)
        } else if value > maxBound {
            return maxBound + rubberBandDistance(value - maxBound, dimension: dimension)
        }
        return value
    }

    @inline(__always)
    private func rubberBandDistance(_ distance: Float, dimension: Float) -> Float {
        guard dimension > 0 else {
            return 0
        }
        let c = Self.rubberBandCoefficient
        return (1 - 1 / (distance * c / dimension + 1)) * dimension
    }

    // MARK: - Velocity Tracking

    private func calculateReleaseVelocity() -> Point {
        guard
            velocityTracker.count >= 2,
            let first = velocityTracker.first,
            let last = velocityTracker.last
        else {
            return .zero
        }
        let dt = last.time - first.time
        guard dt > 0.001 else {
            return .zero
        }
        return Point(
            x: axis.contains(.horizontal) ? -(last.position.x - first.position.x) / dt : 0,
            y: axis.contains(.vertical) ? -(last.position.y - first.position.y) / dt : 0
        )
    }

    private func calculateOverscroll(_ offset: Point) -> Point {
        var result = Point.zero
        if axis.contains(.vertical) {
            if offset.y < contentOffsetBounds.minY {
                result.y = offset.y - contentOffsetBounds.minY
            } else if offset.y > contentOffsetBounds.maxY {
                result.y = offset.y - contentOffsetBounds.maxY
            }
        }
        if axis.contains(.horizontal) {
            if offset.x < contentOffsetBounds.minX {
                result.x = offset.x - contentOffsetBounds.minX
            } else if offset.x > contentOffsetBounds.maxX {
                result.x = offset.x - contentOffsetBounds.maxX
            }
        }
        return result
    }

    private var contentOffsetBounds: Rect = .zero

    private func clampOffset(_ offset: Point) -> Point {
        var clamped = self.contentOffset
        if axis.contains(.vertical) {
            clamped.y = clamp(offset.y, contentOffsetBounds.minY, contentOffsetBounds.maxY)
        }

        if axis.contains(.horizontal) {
            clamped.x = clamp(offset.x, contentOffsetBounds.minX, contentOffsetBounds.maxX)
        }

        return clamped
    }

    private func setContentOffset(_ newValue: Point) {
        guard contentOffset != newValue else {
            return
        }

        contentOffset = newValue
        _ = refreshLazyScrollContent()
        self.invalidateNearestLayer()
        if let containerView = self.owner?.containerView {
            containerView.setNeedsDisplay(in: self.absoluteFrame())
        }
    }

    private func resolvedContentInsets() -> EdgeInsets {
        let safeAreaInsets = environment.safeAreaInsets
        return EdgeInsets(
            top: axis.contains(.vertical) ? safeAreaInsets.top : 0,
            leading: axis.contains(.horizontal) ? safeAreaInsets.leading : 0,
            bottom: axis.contains(.vertical) ? safeAreaInsets.bottom : 0,
            trailing: axis.contains(.horizontal) ? safeAreaInsets.trailing : 0
        )
    }

    override func draw(with context: UIGraphicsContext) {
        var context = context
        context.environment = environment
        context.pushClipRect(self.absoluteFrame())
        context.translateBy(x: -contentOffset.x, y: contentOffset.y)
        super.draw(with: context)
        context.popClipRect()
        context.translateBy(x: contentOffset.x + frame.origin.x, y: -contentOffset.y - frame.origin.y)
        for rect in scrollIndicatorRects {
            context.drawRect(rect, color: .white.opacity(0.45))
        }
    }

    /// Indicator bounds remain in viewport coordinates, independent of content translation.
    var scrollIndicatorRects: [Rect] {
        guard showsIndicators, frame.width >= 10, frame.height >= 10 else {
            return []
        }
        let inset: Float = 3
        let thickness: Float = 4
        let vertical = axis.contains(.vertical) && contentSize.height > frame.height + 0.5
        let horizontal = axis.contains(.horizontal) && contentSize.width > frame.width + 0.5
        var result: [Rect] = []
        if vertical {
            let track = max(0, frame.height - inset * 2 - (horizontal ? thickness + inset : 0))
            let length = min(track, max(24, track * frame.height / contentSize.height))
            let progress = min(1, max(0, contentOffset.y / (contentSize.height - frame.height)))
            result.append(Rect(x: max(0, frame.width - inset - thickness), y: inset + (track - length) * progress, width: thickness, height: length))
        }
        if horizontal {
            let track = max(0, frame.width - inset * 2 - (vertical ? thickness + inset : 0))
            let length = min(track, max(24, track * frame.width / contentSize.width))
            let progress = min(1, max(0, contentOffset.x / (contentSize.width - frame.width)))
            result.append(Rect(x: inset + (track - length) * progress, y: max(0, frame.height - inset - thickness), width: length, height: thickness))
        }
        return result
    }

    override func drawInspectionLayoutBounds(with context: UIGraphicsContext) {
        let viewportContext = inspectionLocalContext(from: context)
        drawInspectionLayoutBorder(with: viewportContext)

        var contentContext = context
        contentContext.environment = environment
        contentContext.pushClipRect(self.absoluteFrame())
        contentContext.translateBy(x: -contentOffset.x, y: contentOffset.y)
        contentContext.translateBy(x: self.frame.origin.x, y: -self.frame.origin.y)
        super.drawInspectionChildLayoutBounds(with: contentContext)
        contentContext.popClipRect()
    }

    override func drawInspectionSelectionBounds(
        with context: UIGraphicsContext,
        mode: UIDebugOverlayMode,
        focusedNode: ViewNode?,
        hitTestNode: ViewNode?
    ) {
        let viewportContext = inspectionLocalContext(from: context)
        drawInspectionSelectionBorderIfNeeded(
            with: viewportContext,
            mode: mode,
            focusedNode: focusedNode,
            hitTestNode: hitTestNode
        )

        var contentContext = context
        contentContext.environment = environment
        contentContext.pushClipRect(self.absoluteFrame())
        contentContext.translateBy(x: -contentOffset.x, y: contentOffset.y)
        contentContext.translateBy(x: self.frame.origin.x, y: -self.frame.origin.y)
        super
            .drawInspectionChildSelectionBounds(
                with: contentContext,
                mode: mode,
                focusedNode: focusedNode,
                hitTestNode: hitTestNode
            )
        contentContext.popClipRect()
    }

    override func drawInspectionRedrawFlashes(
        with context: UIGraphicsContext,
        baselineRevision: UInt64
    ) {
        let viewportContext = inspectionLocalContext(from: context)
        drawInspectionRedrawFlashIfNeeded(
            with: viewportContext,
            baselineRevision: baselineRevision
        )

        var contentContext = context
        contentContext.environment = environment
        contentContext.pushClipRect(self.absoluteFrame())
        contentContext.translateBy(x: -contentOffset.x, y: contentOffset.y)
        contentContext.translateBy(x: self.frame.origin.x, y: -self.frame.origin.y)
        super
            .drawInspectionChildRedrawFlashes(
                with: contentContext,
                baselineRevision: baselineRevision
            )
        contentContext.popClipRect()
    }

    func scrollToViewNodeIfFoundIt(_ id: AnyHashable, anchor: AnchorPoint? = nil) {
        if refreshLazyScrollContent() {
            performLayout()
        }

        if let foundedNode = self.findNodeById(id) {
            let targetFrame = frameInScrollContent(for: foundedNode)
            scrollToContentFrame(targetFrame, anchor: anchor)
            return
        }

        guard let targetFrame = lazyScrollTargetFrame(for: id) else {
            return
        }

        scrollToContentFrame(targetFrame, anchor: anchor)
    }

    func scrollToNodeIfDescendant(_ node: ViewNode, anchor: AnchorPoint? = nil) -> Bool {
        guard self.containsDescendant(node) else {
            return false
        }

        scrollToContentFrame(frameInScrollContent(for: node), anchor: anchor)
        return true
    }

    func scrollToVisibleRect(_ rect: Rect, in node: ViewNode, padding: EdgeInsets = .zero) -> Bool {
        guard self.containsDescendant(node) else {
            return false
        }

        var origin = rect.origin + node.frame.origin
        var current = node.parent
        while let currentNode = current, currentNode !== self {
            origin += currentNode.frame.origin
            current = currentNode.parent
        }

        let target = Rect(origin: origin, size: rect.size)
        var offset = contentOffset

        if axis.contains(.horizontal) {
            let visibleMinX = contentOffset.x + padding.leading
            let visibleMaxX = contentOffset.x + frame.width - padding.trailing

            if target.minX < visibleMinX {
                offset.x = target.minX - padding.leading
            } else if target.maxX > visibleMaxX {
                offset.x = target.maxX - frame.width + padding.trailing
            }
        }

        if axis.contains(.vertical) {
            let visibleMinY = contentOffset.y + padding.top
            let visibleMaxY = contentOffset.y + frame.height - padding.bottom

            if target.minY < visibleMinY {
                offset.y = target.minY - padding.top
            } else if target.maxY > visibleMaxY {
                offset.y = target.maxY - frame.height + padding.bottom
            }
        }

        setContentOffset(clampOffset(offset))
        return true
    }

    func isNearBottom(threshold: Float) -> Bool {
        let remaining = contentSize.height - frame.height - contentOffset.y
        return remaining <= threshold
    }

    private func containsDescendant(_ node: ViewNode) -> Bool {
        var current: ViewNode? = node
        while let currentNode = current {
            if currentNode === self {
                return true
            }
            current = currentNode.parent
        }
        return false
    }

    @inline(__always)
    private func finiteDimension(_ value: Float?) -> Float? {
        guard let value, value.isFinite else {
            return nil
        }

        return value
    }

    @inline(__always)
    private func resolvedDimension(
        proposed: Float?,
        measured: Float,
        isScrollAxis: Bool
    ) -> Float {
        if proposed == .infinity {
            return .infinity
        }

        if let proposed, proposed.isFinite {
            return proposed
        }

        // ScrollView should not claim content size as "ideal" along scrolling axis.
        // Otherwise parent stacks size it to content and overflow becomes zero.
        if isScrollAxis {
            return 0
        }

        return measured.isFinite ? measured : 0
    }

    private func crossAxisOrigin(
        scrollsOnAxis: Bool,
        measured: Float,
        viewport: Float
    ) -> Float {
        guard !scrollsOnAxis, measured.isFinite, measured < viewport else {
            return 0
        }

        return (viewport - measured) * 0.5
    }

    private func scrollToContentFrame(_ frame: Rect, anchor: AnchorPoint?) {
        let anchor = anchor ?? .zero
        let offset = Point(
            x: frame.minX + frame.width * anchor.x - self.frame.width * anchor.x,
            y: frame.minY + frame.height * anchor.y - self.frame.height * anchor.y
        )

        setContentOffset(clampOffset(offset))
    }

    private func frameInScrollContent(for node: ViewNode) -> Rect {
        var origin = node.frame.origin
        var current = node.parent
        while let currentNode = current, currentNode !== self {
            origin += currentNode.frame.origin
            current = currentNode.parent
        }

        return Rect(origin: origin, size: node.frame.size)
    }

    private func lazyScrollTargetFrame(for id: AnyHashable) -> Rect? {
        lazyScrollTargetFrame(in: self, for: id)
    }

    private func lazyScrollTargetFrame(in node: ViewNode, for id: AnyHashable) -> Rect? {
        if let resolver = node as? LazyScrollTargetResolving,
            let frame = resolver.estimatedFrameForScrollTarget(id: id) {
            var origin = frame.origin
            var current: ViewNode? = node
            while let currentNode = current, currentNode !== self {
                origin += currentNode.frame.origin
                current = currentNode.parent
            }
            return Rect(origin: origin, size: frame.size)
        }

        guard let container = node as? ViewContainerNode else {
            if let modifier = node as? ViewModifierNode {
                return lazyScrollTargetFrame(in: modifier.contentNode, for: id)
            }
            return nil
        }

        for child in container.nodes {
            if let frame = lazyScrollTargetFrame(in: child, for: id) {
                return frame
            }
        }

        return nil
    }

    private func refreshLazyScrollContent() -> Bool {
        refreshLazyScrollContent(in: self)
    }

    private func refreshLazyScrollContent(in node: ViewNode) -> Bool {
        if node !== self, let resolver = node as? LazyScrollTargetResolving {
            resolver.refreshVisibleContent()
            return true
        }

        guard let container = node as? ViewContainerNode else {
            if let modifier = node as? ViewModifierNode {
                return refreshLazyScrollContent(in: modifier.contentNode)
            }
            return false
        }

        var didRefresh = false
        for child in container.nodes {
            didRefresh = refreshLazyScrollContent(in: child) || didRefresh
        }
        return didRefresh
    }
}
