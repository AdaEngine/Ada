//
//  FullScreenCoverModifier.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 25.03.2026.
//

import AdaInput
import AdaUtils
import Math

extension View {
    /// Presents a modal view that covers as much of the screen as possible.
    ///
    /// The presented view can be dismissed via the ``DismissAction`` from the environment.
    ///
    /// ```swift
    /// struct ContentView: View {
    ///     @State var showModal = false
    ///
    ///     var body: some View {
    ///         Button("Open") { showModal = true }
    ///             .fullScreenCover(isPresented: $showModal) {
    ///                 ModalView()
    ///             }
    ///     }
    /// }
    /// ```
    public func fullScreenCover<Overlay: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Overlay
    ) -> some View {
        modifier(FullScreenCoverModifier(content: self, isPresented: isPresented, overlay: content))
    }

    /// Presents a modal view when a bound optional item contains a value.
    ///
    /// The presented view receives the unwrapped item and can be dismissed via
    /// the ``DismissAction`` from the environment. Dismissing the view sets the
    /// item binding back to `nil`.
    public func fullScreenCover<Item: Hashable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        let isPresented = Binding<Bool>(
            get: {
                item.wrappedValue != nil
            },
            set: { isPresented in
                if !isPresented {
                    item.wrappedValue = nil
                }
            }
        )

        return fullScreenCover(isPresented: isPresented) {
            if let item = item.wrappedValue {
                content(item)
            }
        }
    }
}

struct FullScreenCoverModifier<WrappedContent: View, Overlay: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let content: WrappedContent
    let isPresented: Binding<Bool>
    let overlay: () -> Overlay

    func buildViewNode(in context: BuildContext) -> ViewNode {
        FullScreenCoverNode(
            contentNode: context.makeNode(from: content),
            content: content,
            isPresented: isPresented,
            overlayBuilder: { inputs in
                let view = overlay()
                return Overlay._makeView(_ViewGraphNode(value: view), inputs: inputs).node
            },
            inputs: context
        )
    }
}

// MARK: - FullScreenCoverNode

final class FullScreenCoverNode: ViewModifierNode {
    private var isPresented: Binding<Bool>
    private let overlayBuilder: (_ViewInputs) -> ViewNode
    private var overlayNode: ViewNode?

    var inspectionChildNodes: [ViewNode] {
        [contentNode] + (overlayNode.map { [$0] } ?? [])
    }
    private var viewInputs: _ViewInputs
    private lazy var dismissAction = DismissAction { [weak self] in
        self?.isPresented.wrappedValue = false
        self?.rebuildOverlay()
    }

    init<Content: View>(
        contentNode: ViewNode,
        content: Content,
        isPresented: Binding<Bool>,
        overlayBuilder: @escaping (_ViewInputs) -> ViewNode,
        inputs: _ViewInputs
    ) {
        self.isPresented = isPresented
        self.overlayBuilder = overlayBuilder
        self.viewInputs = inputs
        super.init(contentNode: contentNode, content: content)
        rebuildOverlay()
    }

    private func rebuildOverlay() {
        let hadOverlay = overlayNode != nil
        if isPresented.wrappedValue {
            var inputs = viewInputs
            inputs.environment.dismiss = dismissAction
            let node = overlayBuilder(inputs)
            node.updateEnvironment(inputs.environment)
            node.parent = self
            if let owner {
                node.updateViewOwner(owner)
            }
            overlayNode = node
        } else {
            overlayNode?.parent = nil
            overlayNode = nil
        }

        invalidateNearestLayer()
        owner?.containerView?.setNeedsDisplay(in: absoluteFrame())
        if isPresented.wrappedValue || hadOverlay {
            performLayout()
        }
    }

    override func performLayout() {
        let proposal = ProposedViewSize(frame.size)
        let origin = Point(x: frame.width * 0.5, y: frame.height * 0.5)

        contentNode.place(in: origin, anchor: .center, proposal: proposal)

        if let overlayNode {
            overlayNode.place(in: origin, anchor: .center, proposal: proposal)
        }
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        contentNode.sizeThatFits(proposal)
    }

    override func updateEnvironment(_ environment: EnvironmentValues) {
        let prevVersion = self.environment.version
        super.updateEnvironment(environment)
        guard self.environment.version != prevVersion else {
            return
        }
        viewInputs.environment = self.environment

        if let overlayNode {
            var overlayEnv = self.environment
            overlayEnv.dismiss = dismissAction
            overlayNode.updateEnvironment(overlayEnv)
        }
    }

    override func updateViewOwner(_ owner: ViewOwner) {
        super.updateViewOwner(owner)
        overlayNode?.updateViewOwner(owner)
    }

    override func draw(with context: UIGraphicsContext) {
        var context = context
        context.environment = environment
        context.translateBy(x: frame.origin.x, y: -frame.origin.y)
        contentNode.draw(with: context)
        overlayNode?.draw(with: context)
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event) else {
            return nil
        }

        if let overlayNode {
            let overlayPoint = overlayNode.convert(point, from: self)
            if let hit = overlayNode.hitTest(overlayPoint, with: event) {
                return hit
            }
        }

        let contentPoint = contentNode.convert(point, from: self)
        return contentNode.hitTest(contentPoint, with: event)
    }

    override func update(from newNode: ViewNode) {
        let wasPresented = isPresented.wrappedValue

        super.update(from: newNode)
        guard let other = newNode as? FullScreenCoverNode else {
            return
        }
        self.isPresented = other.isPresented

        let isPresented = isPresented.wrappedValue
        guard wasPresented || isPresented else {
            return
        }

        rebuildOverlay()
    }

    override func update(_ deltaTime: TimeInterval) {
        super.update(deltaTime)
        // Bindings backed by external models can change without rebuilding the host view.
        if isPresented.wrappedValue != (overlayNode != nil) {
            rebuildOverlay()
        }
        overlayNode?.update(deltaTime)
    }

    override func findNodeById(_ id: AnyHashable) -> ViewNode? {
        overlayNode?.findNodeById(id) ?? super.findNodeById(id)
    }

    override func findNodyByAccessibilityIdentifier(_ identifier: String) -> ViewNode? {
        overlayNode?.findNodyByAccessibilityIdentifier(identifier) ?? super.findNodyByAccessibilityIdentifier(identifier)
    }

    override func didMove(to parent: ViewNode?) {
        super.didMove(to: parent)
        if parent == nil {
            overlayNode?.parent = nil
        }
    }
}
