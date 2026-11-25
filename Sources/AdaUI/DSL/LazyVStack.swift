//
//  LazyVStack.swift
//  AdaEngine
//
//  Created by OpenAI on 27.04.2026.
//

import AdaInput
import AdaUtils
import Math
import OrderedCollections

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
    let rowHeight: ((Data.Element) -> Float)?
    let overscan: Int
    let reuseRowsWithStableIDs: Bool
    let row: (Data.Element) -> Row
    private(set) var offscreenRowLimit = 0

    /// Creates a lazy vertical stack.
    /// - Parameter reuseRowsWithStableIDs: Set this to `true` only when an item's ID changes whenever its rendered row content changes.
    ///   Matching visible rows are then retained across parent updates; environment changes still rebuild them.
    /// - Parameter rowHeight: Known row heights, including offscreen rows. Supply this when heights are controlled by the data rather than measured content.
    public init(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        alignment: HorizontalAlignment = .center,
        spacing: Float? = nil,
        estimatedRowHeight: Float = 72,
        rowHeight: ((Data.Element) -> Float)? = nil,
        overscan: Int = 8,
        reuseRowsWithStableIDs: Bool = false,
        @ViewBuilder row: @escaping (Data.Element) -> Row
    ) {
        self.items = Array(data)
        self.idProvider = { AnyHashable($0[keyPath: id]) }
        self.alignment = alignment
        self.spacing = spacing
        self.estimatedRowHeight = max(1, estimatedRowHeight)
        self.rowHeight = rowHeight
        self.overscan = max(0, overscan)
        self.reuseRowsWithStableIDs = reuseRowsWithStableIDs
        self.row = row
    }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let node = LazyVStackNode(content: self)
        node.updateEnvironment(context.environment)
        return node
    }

    /// Retains up to `limit` recently scrolled-off rows for reuse by the same item ID.
    /// A content update discards these detached rows so their inputs and actions stay current.
    @_spi(AdaEngine)
    public func retainingOffscreenRows(upTo limit: Int) -> Self {
        var stack = self
        stack.offscreenRowLimit = max(0, limit)
        return stack
    }
}

extension LazyVStack where ID == Data.Element.ID, Data.Element: Identifiable {
    /// Creates a lazy vertical stack of identifiable elements.
    /// - Parameter reuseRowsWithStableIDs: Set this to `true` only when an item's ID changes whenever its rendered row content changes.
    ///   Matching visible rows are then retained across parent updates; environment changes still rebuild them.
    /// - Parameter rowHeight: Known row heights, including offscreen rows. Supply this when heights are controlled by the data rather than measured content.
    public init(
        _ data: Data,
        alignment: HorizontalAlignment = .center,
        spacing: Float? = nil,
        estimatedRowHeight: Float = 72,
        rowHeight: ((Data.Element) -> Float)? = nil,
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
            rowHeight: rowHeight,
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
    private var alignment: HorizontalAlignment
    private var spacing: Float?
    private var estimatedRowHeight: Float
    private var overscan: Int
    private var reuseRowsWithStableIDs: Bool
    private var row: (Data.Element) -> Row
    private var offscreenRowLimit: Int
    private var offscreenRows: OrderedDictionary<AnyHashable, ViewNode> = [:]
    private var itemIDs: [AnyHashable]
    private var measuredHeights: [AnyHashable: Float] = [:]
    private var providedHeights: [AnyHashable: Float] = [:]
    private var itemIndices: [AnyHashable: Int] = [:]
    private var rowOffsets: [Float]?

    private var rowSpacing: Float {
        spacing ?? 8
    }

    init(content: Content) {
        self.items = content.items
        self.alignment = content.alignment
        self.spacing = content.spacing
        self.estimatedRowHeight = content.estimatedRowHeight
        self.overscan = content.overscan
        self.reuseRowsWithStableIDs = content.reuseRowsWithStableIDs
        self.row = content.row
        self.offscreenRowLimit = content.offscreenRowLimit
        self.itemIDs = content.items.map(content.idProvider)
        self.providedHeights = Self.providedHeights(for: content)
        super.init(content: content, nodes: [])
        updateItemIndices()
    }

    override func update(from newNode: ViewNode) {
        guard let other = newNode as? LazyVStackNode<Data, ID, Row> else {
            super.update(from: newNode)
            return
        }

        let previousEnvironmentVersion = environment.version
        let previouslyReusedRowsWithStableIDs = reuseRowsWithStableIDs

        offscreenRows.removeAll(keepingCapacity: true)
        self.offscreenRowLimit = other.offscreenRowLimit
        self.environmentTransform = other.environmentTransform
        self.setContent(other.content)
        self.items = other.items
        self.itemIDs = other.itemIDs
        self.itemIndices = other.itemIndices
        rowOffsets = nil
        self.providedHeights = other.providedHeights
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
            in: visibleRange(),
            updateExistingRows: !reuseRowsWithStableIDs || environmentChanged || reusePolicyChanged
        )
    }

    override func updateViewOwner(_ owner: ViewOwner) {
        if self.owner !== owner {
            offscreenRows.removeAll(keepingCapacity: true)
        }
        super.updateViewOwner(owner)
        for node in nodes {
            node.updateViewOwner(owner)
        }
    }

    override func updateEnvironment(_ environment: EnvironmentValues) {
        let previousVersion = self.environment.version
        super.updateEnvironment(environment)
        if self.environment.version != previousVersion {
            offscreenRows.removeAll(keepingCapacity: true)
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
        let range = visibleRange()
        if itemIndices.count != itemIDs.count || nodes.count != range.count
            || !zip(range, nodes).allSatisfy({ itemIDs[$0.0] == nodeIdentity($0.1) }) {
            rebuildVisibleRows(in: range, updateExistingRows: false, isViewportUpdate: true)
        }

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
        var previousIndex = -2
        var nextOffset: Float = 0
        for node in nodes {
            guard
                let id = nodeIdentity(node),
                let index = indexForID(id)
            else {
                continue
            }

            let measuredHeight: Float
            if let providedHeight = providedHeights[id] {
                measuredHeight = providedHeight
            } else {
                let proposal = ProposedViewSize(width: width, height: nil)
                let measuredSize = node.sizeThatFits(proposal)
                measuredHeight = max(0, measuredSize.height.isFinite ? measuredSize.height : estimatedRowHeight)
                if measuredHeights[id] != measuredHeight {
                    measuredHeights[id] = measuredHeight
                    didMeasureNewHeight = true
                }
            }

            // Mounted rows are contiguous in the common case. Advance using the
            // just-measured height so following rows move in the same layout pass.
            let y = index == previousIndex + 1 ? nextOffset : yOffset(for: index)
            previousIndex = index
            nextOffset = (y + measuredHeight) + rowSpacing
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

    private func rebuildVisibleRows(in range: Range<Int>, updateExistingRows: Bool, isViewportUpdate: Bool = false) {
        let oldNodes = nodes
        let canCacheRows = isViewportUpdate && offscreenRowLimit > 0 && itemIndices.count == itemIDs.count
        var oldNodesByID: [AnyHashable: ViewNode] = [:]
        oldNodesByID.reserveCapacity(oldNodes.count)
        for node in oldNodes {
            if let id = nodeIdentity(node) {
                oldNodesByID[id] = node
            }
        }

        var newNodes: [ViewNode] = []
        newNodes.reserveCapacity(max(0, range.upperBound - range.lowerBound))

        for index in range {
            let id = itemIDs[index]
            let oldNode = oldNodesByID.removeValue(forKey: id)
            if isViewportUpdate, let oldNode {
                newNodes.append(oldNode)
                continue
            }
            let resolvedNode: ViewNode

            if let oldNode, updateExistingRows {
                let newNode = makeRowNode(at: index, id: id)
                if newNode.canUpdate(oldNode) {
                    oldNode.update(from: newNode)
                    resolvedNode = oldNode
                } else {
                    detachRow(oldNode)
                    resolvedNode = newNode
                }
            } else {
                resolvedNode = oldNode ?? offscreenRows.removeValue(forKey: id) ?? makeRowNode(at: index, id: id)
            }

            resolvedNode.parent = self
            resolvedNode.updateLayoutProperties(layoutProperties)
            resolvedNode.updateEnvironment(environment)
            if let owner, resolvedNode.owner !== owner {
                resolvedNode.updateViewOwner(owner)
            }
            newNodes.append(resolvedNode)
        }

        for oldNode in oldNodes {
            guard let id = nodeIdentity(oldNode), oldNodesByID[id] === oldNode else {
                continue
            }
            let canReuseRow = detachRow(oldNode)
            if canCacheRows, canReuseRow {
                offscreenRows[id] = oldNode
            }
        }

        if offscreenRows.count > offscreenRowLimit {
            offscreenRows.removeFirst(offscreenRows.count - offscreenRowLimit)
        }

        nodes = newNodes
    }

    @discardableResult
    private func detachRow(_ node: ViewNode) -> Bool {
        let hadActiveInput = offscreenRowLimit > 0 && owner?.deactivateInput(in: node) == true
        node.parent = nil
        return !hadActiveInput
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

        // Overlapping rows can have nonmonotonic ends. Preserve the original
        // scan for negative spacing rather than searching an unordered range.
        if !providedHeights.isEmpty, rowSpacing >= 0, rowSpacing.isFinite, maxY.isFinite {
            let offsets = offsetsForRows()
            let start = firstRowIndex { index in
                offsets[index] + height(for: itemIDs[index]) >= minY
            }
            if start < items.count {
                let end = firstRowIndex { offsets[$0] > maxY }
                return start..<max(start + 1, end)
            }
            return itemIDs.indices
        }

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

        var origin = frame.origin
        var ancestor = parent
        while let node = ancestor, node !== scrollView {
            origin += node.frame.origin
            ancestor = node.parent
        }
        return Rect(
            x: scrollView.contentOffset.x - origin.x,
            y: scrollView.contentOffset.y - origin.y,
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
        if !providedHeights.isEmpty {
            return offsetsForRows()[targetIndex]
        }
        // Measured rows change during layout. Walk only the prefix we need;
        // the placement loop then advances through contiguous mounted rows.
        var y: Float = 0
        for index in 0..<targetIndex {
            y += height(for: itemIDs[index])
            y += rowSpacing
        }
        return y
    }

    private func offsetsForRows() -> [Float] {
        if let rowOffsets {
            return rowOffsets
        }
        var offsets: [Float] = []
        offsets.reserveCapacity(itemIDs.count)
        var y: Float = 0
        for id in itemIDs {
            offsets.append(y)
            y += height(for: id)
            y += rowSpacing
        }
        rowOffsets = offsets
        return offsets
    }

    private func firstRowIndex(where predicate: (Int) -> Bool) -> Int {
        var lower = 0
        var upper = itemIDs.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if predicate(middle) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }

    private func updateItemIndices() {
        itemIndices = Dictionary(itemIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }

    private func height(for id: AnyHashable) -> Float {
        providedHeights[id] ?? measuredHeights[id] ?? estimatedRowHeight
    }

    private static func providedHeights(for content: Content) -> [AnyHashable: Float] {
        guard let rowHeight = content.rowHeight else {
            return [:]
        }
        return Dictionary(content.items.map { item in
            let height = rowHeight(item)
            return (content.idProvider(item), height.isFinite ? max(0, height) : content.estimatedRowHeight)
        }, uniquingKeysWith: { _, latest in latest })
    }

    private func indexForID(_ id: AnyHashable) -> Int? {
        itemIndices[id]
    }

    private func nodeIdentity(_ node: ViewNode) -> AnyHashable? {
        (node as? IDViewNodeModifier)?.identifier
    }
}
