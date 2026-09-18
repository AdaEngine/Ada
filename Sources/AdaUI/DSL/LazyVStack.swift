//
//  LazyVStack.swift
//  AdaEngine
//
//  Created by OpenAI on 27.04.2026.
//

import AdaInput
import AdaUtils
import Math

/// A vertical stack that builds only rows near the visible scroll viewport.
@MainActor @preconcurrency
public struct LazyVStack<Data: RandomAccessCollection, ID: Hashable, Row: View>: View, ViewNodeBuilder {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    let items: [Data.Element]
    let idProvider: (Data.Element) -> AnyHashable
    let alignment: HorizontalAlignment
    let spacing: Float?
    let estimatedRowHeight: Float
    let overscan: Int
    let reuseRowsWithStableIDs: Bool
    let row: (Data.Element) -> Row

    /// Creates a lazy vertical stack.
    /// - Parameter reuseRowsWithStableIDs: Set this to `true` only when an item's ID changes whenever its rendered row content changes.
    ///   Matching visible rows are then retained across parent updates; environment changes still rebuild them.
    public init(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        alignment: HorizontalAlignment = .center,
        spacing: Float? = nil,
        estimatedRowHeight: Float = 72,
        overscan: Int = 8,
        reuseRowsWithStableIDs: Bool = false,
        @ViewBuilder row: @escaping (Data.Element) -> Row
    ) {
        self.items = Array(data)
        self.idProvider = { AnyHashable($0[keyPath: id]) }
        self.alignment = alignment
        self.spacing = spacing
        self.estimatedRowHeight = max(1, estimatedRowHeight)
        self.overscan = max(0, overscan)
        self.reuseRowsWithStableIDs = reuseRowsWithStableIDs
        self.row = row
    }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let node = LazyVStackNode(content: self)
        node.updateEnvironment(context.environment)
        return node
    }
}

extension LazyVStack where ID == Data.Element.ID, Data.Element: Identifiable {
    /// Creates a lazy vertical stack of identifiable elements.
    /// - Parameter reuseRowsWithStableIDs: Set this to `true` only when an item's ID changes whenever its rendered row content changes.
    ///   Matching visible rows are then retained across parent updates; environment changes still rebuild them.
    public init(
        _ data: Data,
        alignment: HorizontalAlignment = .center,
        spacing: Float? = nil,
        estimatedRowHeight: Float = 72,
        overscan: Int = 8,
        reuseRowsWithStableIDs: Bool = false,
        @ViewBuilder row: @escaping (Data.Element) -> Row
    ) {
        self.init(
            data,
            id: \.id,
            alignment: alignment,
            spacing: spacing,
            estimatedRowHeight: estimatedRowHeight,
            overscan: overscan,
            reuseRowsWithStableIDs: reuseRowsWithStableIDs,
            row: row
        )
    }
}

@MainActor
protocol LazyScrollTargetResolving: AnyObject {
    func estimatedFrameForScrollTarget(id: AnyHashable) -> Rect?
    func refreshVisibleContent()
}

@MainActor
final class LazyVStackNode<Data: RandomAccessCollection, ID: Hashable, Row: View>: ViewContainerNode, LazyScrollTargetResolving {
    typealias Content = LazyVStack<Data, ID, Row>

    private var items: [Data.Element]
    private var idProvider: (Data.Element) -> AnyHashable
    private var alignment: HorizontalAlignment
    private var spacing: Float?
    private var estimatedRowHeight: Float
    private var overscan: Int
    private var reuseRowsWithStableIDs: Bool
    private var row: (Data.Element) -> Row
    private var itemIDs: [AnyHashable]
    private var measuredHeights: [AnyHashable: Float] = [:]

    private var rowSpacing: Float {
        spacing ?? 8
    }

    init(content: Content) {
        self.items = content.items
        self.idProvider = content.idProvider
        self.alignment = content.alignment
        self.spacing = content.spacing
        self.estimatedRowHeight = content.estimatedRowHeight
        self.overscan = content.overscan
        self.reuseRowsWithStableIDs = content.reuseRowsWithStableIDs
        self.row = content.row
        self.itemIDs = content.items.map(content.idProvider)
        super.init(content: content, nodes: [])
    }

    override func update(from newNode: ViewNode) {
        guard let other = newNode as? LazyVStackNode<Data, ID, Row> else {
            super.update(from: newNode)
            return
        }

        let previousEnvironmentVersion = environment.version
        let previouslyReusedRowsWithStableIDs = reuseRowsWithStableIDs
        let updatedItemIDs = other.items.map(other.idProvider)

        self.environmentTransform = other.environmentTransform
        self.setContent(other.content)
        self.items = other.items
        self.itemIDs = updatedItemIDs
        self.idProvider = other.idProvider
        self.alignment = other.alignment
        self.spacing = other.spacing
        self.estimatedRowHeight = other.estimatedRowHeight
        self.overscan = other.overscan
        self.reuseRowsWithStableIDs = other.reuseRowsWithStableIDs
        self.row = other.row
        self.updateEnvironment(other.environment)

        let currentIDs = Set(itemIDs)
        measuredHeights = measuredHeights.filter { currentIDs.contains($0.key) }
        let environmentChanged = environment.version != previousEnvironmentVersion
        let reusePolicyChanged = reuseRowsWithStableIDs != previouslyReusedRowsWithStableIDs
        rebuildVisibleRows(
            updateExistingRows: !reuseRowsWithStableIDs || environmentChanged || reusePolicyChanged
        )
    }

    override func updateViewOwner(_ owner: ViewOwner) {
        super.updateViewOwner(owner)
        for node in nodes {
            node.updateViewOwner(owner)
        }
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        let width: Float
        if let proposedWidth = proposal.width, proposedWidth.isFinite {
            width = proposedWidth
        } else {
            width = nodes.reduce(0) { max($0, $1.frame.width) }
        }

        return Size(width: width, height: totalEstimatedHeight())
    }

    override func performLayout() {
        rebuildVisibleRows(updateExistingRows: false)

        let width = frame.width
        let xOrigin: Float
        let anchor: AnchorPoint
        switch alignment.resolved(for: environment.layoutDirection) {
        case .leading:
            xOrigin = 0
            anchor = .topLeading
        case .trailing:
            xOrigin = width
            anchor = .topTrailing
        case .center:
            xOrigin = width * 0.5
            anchor = .top
        }

        var didMeasureNewHeight = false
        for node in nodes {
            guard
                let id = nodeIdentity(node),
                let index = indexForID(id)
            else {
                continue
            }

            let proposal = ProposedViewSize(width: width, height: nil)
            let measuredSize = node.sizeThatFits(proposal)
            let measuredHeight = max(0, measuredSize.height.isFinite ? measuredSize.height : estimatedRowHeight)
            if measuredHeights[id] != measuredHeight {
                measuredHeights[id] = measuredHeight
                didMeasureNewHeight = true
            }

            let y = yOffset(for: index)
            node.place(
                in: Point(x: xOrigin, y: y),
                anchor: anchor,
                proposal: ProposedViewSize(width: width, height: measuredHeight)
            )
        }

        if didMeasureNewHeight {
            owner?.containerView?.setNeedsLayout()
        }

        invalidateLayerIfNeeded()
    }

    override func findNodeById(_ id: AnyHashable) -> ViewNode? {
        for node in nodes {
            if let found = node.findNodeById(id) {
                return found
            }
        }

        return nil
    }

    override func findNodyByAccessibilityIdentifier(_ identifier: String) -> ViewNode? {
        if let node = super.findNodyByAccessibilityIdentifier(identifier) {
            return node
        }

        for node in nodes {
            if let found = node.findNodyByAccessibilityIdentifier(identifier) {
                return found
            }
        }

        return nil
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        for node in nodes {
            node.buildMenu(with: builder)
        }
    }

    override func updateLayoutProperties(_ props: LayoutProperties) {
        super.updateLayoutProperties(props)
        for node in nodes {
            node.updateLayoutProperties(props)
        }
    }

    override func update(_ deltaTime: AdaUtils.TimeInterval) {
        for node in nodes {
            node.update(deltaTime)
        }
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        for node in nodes.reversed() {
            let newPoint = node.convert(point, from: self)
            if let node = node.hitTest(newPoint, with: event) {
                return node
            }
        }

        return super.hitTest(point, with: event)
    }

    override func draw(with context: UIGraphicsContext) {
        var context = context
        context.environment = environment
        context.translateBy(x: self.frame.origin.x, y: -self.frame.origin.y)
        for node in nodes {
            node.draw(with: context)
        }
    }

    override func drawInspectionChildLayoutBounds(with context: UIGraphicsContext) {
        for node in nodes {
            node.drawInspectionLayoutBounds(with: context)
        }
    }

    override func drawInspectionChildRedrawFlashes(
        with context: UIGraphicsContext,
        baselineRevision: UInt64
    ) {
        for node in nodes {
            node.drawInspectionRedrawFlashes(
                with: context,
                baselineRevision: baselineRevision
            )
        }
    }

    override func drawInspectionChildSelectionBounds(
        with context: UIGraphicsContext,
        mode: UIDebugOverlayMode,
        focusedNode: ViewNode?,
        hitTestNode: ViewNode?
    ) {
        for node in nodes {
            node.drawInspectionSelectionBounds(
                with: context,
                mode: mode,
                focusedNode: focusedNode,
                hitTestNode: hitTestNode
            )
        }
    }

    func estimatedFrameForScrollTarget(id: AnyHashable) -> Rect? {
        guard let index = indexForID(id) else {
            return nil
        }

        return Rect(
            x: 0,
            y: yOffset(for: index),
            width: frame.width,
            height: height(for: id)
        )
    }

    func refreshVisibleContent() {
        performLayout()
    }

    private func rebuildVisibleRows(updateExistingRows: Bool) {
        let range = visibleRange()
        let oldNodes = nodes
        var oldNodesByID: [AnyHashable: ViewNode] = [:]
        for node in oldNodes {
            if let id = nodeIdentity(node) {
                oldNodesByID[id] = node
            }
        }

        var newNodes: [ViewNode] = []
        newNodes.reserveCapacity(max(0, range.upperBound - range.lowerBound))

        for index in range {
            let id = itemIDs[index]
            let resolvedNode: ViewNode

            if let oldNode = oldNodesByID.removeValue(forKey: id) {
                if updateExistingRows {
                    let newNode = makeRowNode(at: index, id: id)
                    if newNode.canUpdate(oldNode) {
                        oldNode.update(from: newNode)
                        resolvedNode = oldNode
                    } else {
                        resolvedNode = newNode
                    }
                } else {
                    resolvedNode = oldNode
                }
            } else {
                resolvedNode = makeRowNode(at: index, id: id)
            }

            resolvedNode.parent = self
            resolvedNode.updateLayoutProperties(layoutProperties)
            resolvedNode.updateEnvironment(environment)
            if let owner, resolvedNode.owner !== owner {
                resolvedNode.updateViewOwner(owner)
            }
            newNodes.append(resolvedNode)
        }

        for oldNode in oldNodesByID.values {
            oldNode.parent = nil
        }

        nodes = newNodes
    }

    private func makeRowNode(at index: Int, id: AnyHashable) -> ViewNode {
        let rowView = row(items[index])
        let identifiedRow = IDView(id: id, content: rowView)
        var inputs = _ViewInputs(parentNode: self, environment: environment)
        inputs.layout = VStackLayout(alignment: alignment, spacing: spacing)
        return IDView<Row>._makeView(_ViewGraphNode(value: identifiedRow), inputs: inputs).node
    }

    private func visibleRange() -> Range<Int> {
        guard !items.isEmpty else {
            return 0..<0
        }

        let viewport = viewportRect()
        let overscanExtent = Float(overscan) * (estimatedRowHeight + rowSpacing)
        let minY = max(0, viewport.minY - overscanExtent)
        let maxY = viewport.maxY + overscanExtent

        var firstVisibleIndex = 0
        var lastVisibleIndex = items.count - 1
        var y: Float = 0
        var foundStart = false

        for index in items.indices {
            let id = itemIDs[index]
            let height = height(for: id)
            let rowMinY = y
            let rowMaxY = y + height

            if !foundStart, rowMaxY >= minY {
                firstVisibleIndex = index
                foundStart = true
            }

            if foundStart, rowMinY > maxY {
                lastVisibleIndex = max(firstVisibleIndex, index - 1)
                break
            }

            if index == items.count - 1 {
                lastVisibleIndex = index
            }

            y = rowMaxY
            if index != items.count - 1 {
                y += rowSpacing
            }
        }

        return firstVisibleIndex..<(lastVisibleIndex + 1)
    }

    private func viewportRect() -> Rect {
        guard let scrollView = nearestScrollView() else {
            return Rect(origin: .zero, size: frame.size)
        }

        return Rect(
            x: scrollView.contentOffset.x - frame.origin.x,
            y: scrollView.contentOffset.y - frame.origin.y,
            width: scrollView.frame.width,
            height: scrollView.frame.height
        )
    }

    private func nearestScrollView() -> ScrollViewNode? {
        var current = parent
        while let node = current {
            if let scrollView = node as? ScrollViewNode {
                return scrollView
            }
            current = node.parent
        }
        return nil
    }

    private func totalEstimatedHeight() -> Float {
        guard !items.isEmpty else {
            return 0
        }

        let rowHeights = itemIDs.reduce(Float.zero) { partialResult, id in
            partialResult + height(for: id)
        }
        return rowHeights + Float(items.count - 1) * rowSpacing
    }

    private func yOffset(for targetIndex: Int) -> Float {
        guard targetIndex > 0 else {
            return 0
        }

        var y: Float = 0
        for index in 0..<targetIndex {
            y += height(for: itemIDs[index])
            y += rowSpacing
        }
        return y
    }

    private func height(for id: AnyHashable) -> Float {
        measuredHeights[id] ?? estimatedRowHeight
    }

    private func indexForID(_ id: AnyHashable) -> Int? {
        itemIDs.firstIndex(of: id)
    }

    private func nodeIdentity(_ node: ViewNode) -> AnyHashable? {
        (node as? IDViewNodeModifier)?.identifier
    }
}
