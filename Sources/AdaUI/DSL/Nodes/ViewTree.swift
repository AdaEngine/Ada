//
//  ViewTree.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 07.06.2024.
//

import AdaInput
import AdaUtils
import Foundation
import Math

@MainActor
final class ViewTree<Content: View> {
    let rootView: Content
    private(set) var rootNode: ViewRootNode

    init(rootView: Content, environment: EnvironmentValues = EnvironmentValues()) {
        self.rootView = rootView

        let inputs = _ViewInputs(
            parentNode: nil,
            environment: environment
        )

        let contentNode = Content._makeView(_ViewGraphNode(value: rootView), inputs: inputs)
        self.rootNode = ViewRootNode(contentNode: contentNode.node, content: rootView)
        self.rootNode.mergeEnvironment(environment)
    }

    func setViewOwner(_ owner: ViewOwner) {
        self.rootNode.updateViewOwner(owner)
    }

    func renderGraph(renderContext: UIGraphicsContext) {
        self.rootNode.draw(with: renderContext)
    }
}

/// The root node that holds user view.
final class ViewRootNode: ViewNode {
    let contentNode: ViewNode

    static let rootCoordinateSpace = NamedViewCoordinateSpace(UUID().uuidString)

    override var transientEnvironmentChildren: [ViewNode] {
        [contentNode]
    }

    init<Root: View>(contentNode: ViewNode, content: Root) {
        self.contentNode = contentNode
        super.init(content: content)

        self.contentNode.parent = self
        self.environment.coordinateSpaces.compact()
        self.environment.coordinateSpaces.containers[Self.rootCoordinateSpace.name] = WeakBox(self)
    }

    override func invalidateContent() {
        UILayoutDebugCounters.recordContentInvalidation()
        UILayoutDebugCounters.recordRebuild()
        let inputs = _ViewInputs(parentNode: nil, environment: self.environment)

        func makeView<V: View>(_ view: V) -> _ViewOutputs {
            V._makeView(_ViewGraphNode(value: view), inputs: inputs)
        }

        let outputs = makeView(self.content)
        self.contentNode.update(from: outputs.node)
        self.markNeedsLayout()
        owner?.containerView?.setNeedsLayout()
    }

    override func performLayout() {
        let insets = environment.safeAreaInsets
        let safeWidth = max(0, frame.width - insets.leading - insets.trailing)
        let safeHeight = max(0, frame.height - insets.top - insets.bottom)
        let centerX = insets.leading + safeWidth * 0.5
        let centerY = insets.top + safeHeight * 0.5
        contentNode.place(
            in: Point(centerX, centerY),
            anchor: .center,
            proposal: ProposedViewSize(width: safeWidth, height: safeHeight)
        )
    }

    override func updateEnvironment(_ environment: EnvironmentValues) {
        let prevVersion = self.environment.version
        super.updateEnvironment(environment)
        guard self.environment.version != prevVersion else {
            return
        }
        contentNode.mergeEnvironment(environment)
    }

    override func update(_ deltaTime: AdaUtils.TimeInterval) {
        contentNode.update(deltaTime)
    }

    override func draw(with context: UIGraphicsContext) {
        contentNode.draw(with: context)
        super.draw(with: context)
    }

    override func drawInspectionChildLayoutBounds(with context: UIGraphicsContext) {
        contentNode.drawInspectionLayoutBounds(with: context)
    }

    override func drawInspectionChildRedrawFlashes(
        with context: UIGraphicsContext,
        baselineRevision: UInt64
    ) {
        contentNode.drawInspectionRedrawFlashes(
            with: context,
            baselineRevision: baselineRevision
        )
    }

    override func drawInspectionChildSelectionBounds(
        with context: UIGraphicsContext,
        mode: UIDebugOverlayMode,
        focusedNode: ViewNode?,
        hitTestNode: ViewNode?
    ) {
        contentNode.drawInspectionSelectionBounds(
            with: context,
            mode: mode,
            focusedNode: focusedNode,
            hitTestNode: hitTestNode
        )
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        let newPoint = contentNode.convert(point, from: self)
        return contentNode.hitTest(newPoint, with: event)
    }

    override func point(inside point: Point, with event: any InputEvent) -> Bool {
        // Must match ``hitTest``: `contentNode` is placed with a non-zero origin (centered in
        // the safe area), so root-local points must be converted before testing the subtree.
        let newPoint = contentNode.convert(point, from: self)
        return contentNode.point(inside: newPoint, with: event)
    }

    override func onMouseEvent(_ event: MouseEvent) {
        contentNode.onMouseEvent(event)
    }

    override func updateViewOwner(_ owner: ViewOwner) {
        contentNode.updateViewOwner(owner)
    }

    override func onReceiveEvent(_ event: any InputEvent) {
        contentNode.onReceiveEvent(event)
    }

    override func findNodyByAccessibilityIdentifier(_ identifier: String) -> ViewNode? {
        self.contentNode.findNodyByAccessibilityIdentifier(identifier)
    }

    override func findNodeById(_ id: AnyHashable) -> ViewNode? {
        self.contentNode.findNodeById(id)
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        contentNode.buildMenu(with: builder)
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        contentNode.onTouchesEvent(touches)
    }
}
