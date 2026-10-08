//
//  TabContainerLegacy.swift
//  AdaEngine
//
//  Deprecated TabContainer API. Use TabView instead.
//

import AdaInput
import AdaRender
import AdaText
import AdaUtils
import Math

// MARK: - TabContainer (deprecated)

/// A tab container view.
///
/// - Note: Deprecated. Use ``TabView`` with ``Tab`` items instead.
@available(*, deprecated, renamed: "TabView")
@MainActor @preconcurrency
public struct TabContainer<Selection: Hashable, Content: View>: View, ViewNodeBuilder {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    let labels: [String]
    let values: [Selection]
    let selection: Binding<Selection>
    let content: (Selection) -> Content

    public init(
        _ tabs: [(label: String, value: Selection)],
        selection: Binding<Selection>,
        @ViewBuilder content: @escaping (Selection) -> Content
    ) {
        self.labels = tabs.map(\.label)
        self.values = tabs.map(\.value)
        self.selection = selection
        self.content = content
    }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        TabContainerNode(inputs: context, container: self)
    }
}

@available(*, deprecated)
extension TabContainer where Selection == Int {
    public init(
        _ labels: [String],
        selection: Binding<Int>,
        @ViewBuilder content: @escaping (Int) -> Content
    ) {
        self.labels = labels
        self.values = Array(labels.indices)
        self.selection = selection
        self.content = content
    }
}

// MARK: - TabContainerNode

@available(*, deprecated)
private final class TabContainerNode<Selection: Hashable, Content: View>: ViewNode {
    private var labels: [String]
    private var values: [Selection]
    private var selectionBinding: Binding<Selection>
    private var contentBuilder: (Selection) -> Content
    private var viewInputs: _ViewInputs

    private var tabBarNode: LayoutViewContainerNode
    private var contentNode: ViewNode

    private static var tabBarHeight: Float { 40 }
    private static var tabBarBottomBorder: Float { 2 }
    private static var borderColor: Color { .fromHex(0x2A2A2A) }

    init(inputs: _ViewInputs, container: TabContainer<Selection, Content>) {
        self.labels = container.labels
        self.values = container.values
        self.selectionBinding = container.selection
        self.contentBuilder = container.content
        self.viewInputs = inputs

        let selected = container.selection.wrappedValue
        self.tabBarNode = Self.buildTabBar(labels: container.labels, values: container.values, selected: selected, inputs: inputs, onSelect: { _ in })
        self.contentNode = Self.buildContent(for: selected, builder: container.content, inputs: inputs)

        super.init(content: container)

        self.tabBarNode.parent = self
        self.contentNode.parent = self

        let weakSelf = WeakBox(self)
        self.tabBarNode = Self.buildTabBar(
            labels: container.labels,
            values: container.values,
            selected: selected,
            inputs: inputs,
            onSelect: { value in
                weakSelf.value?.selectTab(value)
            }
        )
        self.tabBarNode.parent = self
    }

    override var canBecomeFocused: Bool { false }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        let width = proposal.width ?? 300
        let tabBarSize = tabBarNode.sizeThatFits(ProposedViewSize(width: width, height: Self.tabBarHeight))
        let contentProposal = ProposedViewSize(width: width, height: proposal.height.map { max(0, $0 - tabBarSize.height) })
        let contentSize = contentNode.sizeThatFits(contentProposal)
        return Size(width: max(tabBarSize.width, contentSize.width), height: tabBarSize.height + contentSize.height)
    }

    override func performLayout() {
        tabBarNode.place(
            in: Point(x: frame.width * 0.5, y: Self.tabBarHeight * 0.5),
            anchor: .center,
            proposal: ProposedViewSize(width: frame.width, height: Self.tabBarHeight)
        )
        let contentHeight = max(0, frame.height - Self.tabBarHeight)
        contentNode.place(
            in: Point(x: frame.width * 0.5, y: Self.tabBarHeight + contentHeight * 0.5),
            anchor: .center,
            proposal: ProposedViewSize(width: frame.width, height: contentHeight)
        )
    }

    override func update(from newNode: ViewNode) {
        guard let other = newNode as? TabContainerNode<Selection, Content> else {
            return
        }
        self.labels = other.labels
        self.values = other.values
        self.selectionBinding = other.selectionBinding
        self.contentBuilder = other.contentBuilder
        self.viewInputs = other.viewInputs
        super.update(from: other)
        self.viewInputs.environment = self.environment
        rebuildAll()
    }

    override func invalidateContent() { rebuildAll() }

    override func updateEnvironment(_ environment: EnvironmentValues) {
        let prevVersion = self.environment.version
        super.updateEnvironment(environment)
        guard self.environment.version != prevVersion else {
            return
        }
        viewInputs.environment = self.environment
        tabBarNode.updateEnvironment(self.environment)
        contentNode.updateEnvironment(self.environment)
    }

    override func updateViewOwner(_ owner: ViewOwner) {
        super.updateViewOwner(owner)
        tabBarNode.updateViewOwner(owner)
        contentNode.updateViewOwner(owner)
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event) else {
            return nil
        }
        let tabBarPoint = tabBarNode.convert(point, from: self)
        if let hit = tabBarNode.hitTest(tabBarPoint, with: event) {
            return hit
        }
        let contentPoint = contentNode.convert(point, from: self)
        return contentNode.hitTest(contentPoint, with: event)
    }

    override func draw(with context: UIGraphicsContext) {
        var ctx = context
        ctx.environment = environment
        ctx.translateBy(x: frame.origin.x, y: -frame.origin.y)
        tabBarNode.draw(with: ctx)
        ctx.drawLine(
            start: Point(0, -Self.tabBarHeight),
            end: Point(frame.width, -Self.tabBarHeight),
            lineWidth: Self.tabBarBottomBorder,
            color: Self.borderColor
        )
        contentNode.draw(with: ctx)
    }

    override func update(_ deltaTime: TimeInterval) {
        tabBarNode.update(deltaTime)
        contentNode.update(deltaTime)
    }

    override func findNodeById(_ id: AnyHashable) -> ViewNode? {
        tabBarNode.findNodeById(id) ?? contentNode.findNodeById(id)
    }

    override func findNodyByAccessibilityIdentifier(_ identifier: String) -> ViewNode? {
        if let r = super.findNodyByAccessibilityIdentifier(identifier) {
            return r
        }
        return tabBarNode.findNodyByAccessibilityIdentifier(identifier)
            ?? contentNode.findNodyByAccessibilityIdentifier(identifier)
    }

    private func selectTab(_ value: Selection) {
        guard selectionBinding.wrappedValue != value else {
            return
        }
        selectionBinding.wrappedValue = value
        rebuildAll()
    }

    private func rebuildAll() {
        let selected = selectionBinding.wrappedValue
        let weakSelf = WeakBox(self)
        let newTabBar = Self.buildTabBar(
            labels: labels,
            values: values,
            selected: selected,
            inputs: viewInputs,
            onSelect: { value in
                weakSelf.value?.selectTab(value)
            }
        )
        tabBarNode.update(from: newTabBar)
        tabBarNode.parent = self
        if let owner {
            tabBarNode.updateViewOwner(owner)
        }
        tabBarNode.updateEnvironment(environment)

        contentNode.parent = nil
        contentNode = Self.buildContent(for: selected, builder: contentBuilder, inputs: viewInputs)
        contentNode.parent = self
        if let owner {
            contentNode.updateViewOwner(owner)
        }
        contentNode.updateEnvironment(environment)

        self.invalidateNearestLayer()
        if let containerView = self.owner?.containerView {
            containerView.setNeedsDisplay(in: self.absoluteFrame())
        }
        self.performLayout()
    }

    private static func buildTabBar(
        labels: [String],
        values: [Selection],
        selected: Selection,
        inputs: _ViewInputs,
        onSelect: @escaping (Selection) -> Void
    ) -> LayoutViewContainerNode {
        let nodes: [ViewNode] = (0..<labels.count)
            .map { index in
                let btn = LegacyTabButton(label: labels[index], isSelected: values[index] == selected, action: { onSelect(values[index]) })
                return LegacyTabButtonNode(content: btn, inputs: inputs)
            }
        return LayoutViewContainerNode(layout: HStackLayout(alignment: .center, spacing: 0), content: EmptyView(), nodes: nodes)
    }

    private static func buildContent(
        for selection: Selection,
        builder: @escaping (Selection) -> Content,
        inputs: _ViewInputs
    ) -> ViewNode {
        let view = builder(selection)
        return Content._makeView(_ViewGraphNode(value: view), inputs: inputs).node
    }
}

// MARK: - LegacyTabButton

private struct LegacyTabButton: View, ViewNodeBuilder {
    typealias Body = Never
    var body: Never { fatalError("Unreachable code") }
    let label: String
    let isSelected: Bool
    let action: () -> Void
    func buildViewNode(in context: BuildContext) -> ViewNode {
        LegacyTabButtonNode(content: self, inputs: context)
    }
}

private final class LegacyTabButtonNode: ViewNode {
    private static var textColor: Color { .fromHex(0x666666) }
    private static var selectedTextColor: Color { .fromHex(0xF0F0F0) }
    private static var indicatorColor: Color { .fromHex(0xFF2D6F) }

    private var label: String
    private var isSelected: Bool
    private var action: () -> Void
    private var isHighlighted = false

    init(content: LegacyTabButton, inputs: _ViewInputs) {
        self.label = content.label
        self.isSelected = content.isSelected
        self.action = content.action
        super.init(content: content)
        self.updateEnvironment(inputs.environment)
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        let pointSize = resolvedPointSize()
        let width = Float(label.count) * pointSize * 0.55 + 40
        return Size(width: width, height: proposal.height ?? 40)
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event) else {
            return nil
        }
        return self
    }

    override func onMouseEvent(_ event: MouseEvent) {
        switch event.phase {
        case .began,
            .changed:
            isHighlighted = true
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

    override func draw(with context: UIGraphicsContext) {
        var ctx = context
        ctx.environment = environment
        ctx.translateBy(x: frame.origin.x, y: -frame.origin.y)
        let bounds = Rect(x: 0, y: 0, width: frame.width, height: frame.height)
        if isHighlighted {
            ctx.drawRect(bounds, color: Color.fromHex(0x1A1A1A))
        }

        let pointSize = resolvedPointSize()
        let color: Color = isSelected ? Self.selectedTextColor : Self.textColor
        if let font = resolvedFont() {
            var attributes = TextAttributeContainer()
            attributes.font = font
            attributes.foregroundColor = color
            let container = TextContainer(text: AttributedText(label, attributes: attributes), textAlignment: .center)
            let lm = TextLayoutManager()
            lm.setTextContainer(container)
            lm.fitToSize(Size(width: bounds.width, height: bounds.height))
            let textW = Float(label.count) * pointSize * 0.55
            let textX = (bounds.width - textW) * 0.5
            let textY = -bounds.height * 0.5 - pointSize * 0.35
            ctx.translateBy(x: textX, y: textY)
            for line in lm.textLines {
                for run in line {
                    for glyph in run {
                        ctx.draw(glyph)
                    }
                }
            }
        }

        if isSelected {
            ctx.drawRect(Rect(x: 0, y: -bounds.height, width: bounds.width, height: 3), color: Self.indicatorColor)
        }
    }

    override func update(from newNode: ViewNode) {
        super.update(from: newNode)
        guard let other = newNode as? LegacyTabButtonNode else {
            return
        }
        self.label = other.label
        self.isSelected = other.isSelected
        self.action = other.action
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
