//
//  FullScreenCoverModifier.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 25.03.2026.
//

import AdaInput
import AdaUtils
import Math

/// The animation used to insert and dismiss a full-screen modal.
public enum FullScreenCoverTransition: Sendable {
    /// Moves the modal up from the bottom edge.
    case slide
    /// Fades the modal in place without translating or scaling it.
    case opacity
}

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
        transition: FullScreenCoverTransition = .slide,
        @ViewBuilder content: @escaping () -> Overlay
    ) -> some View {
        modifier(FullScreenCoverModifier(content: self, isPresented: isPresented, overlay: content, style: transition == .opacity ? .fade : .cover))
    }

    /// Presents a modal view when a bound optional item contains a value.
    ///
    /// The presented view receives the unwrapped item and can be dismissed via
    /// the ``DismissAction`` from the environment. Dismissing the view sets the
    /// item binding back to `nil`.
    public func fullScreenCover<Item: Hashable, Content: View>(
        item: Binding<Item?>,
        transition: FullScreenCoverTransition = .slide,
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

        return fullScreenCover(isPresented: isPresented, transition: transition) {
            if let item = item.wrappedValue {
                content(item).id(item)
            }
        }
    }

    /// Presents a centered modal sheet with a dimmed background and a fade/scale transition.
    public func sheet<Overlay: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Overlay
    ) -> some View {
        modifier(FullScreenCoverModifier(content: self, isPresented: isPresented, overlay: content, style: .sheet))
    }

    /// Presents a sheet for an item, preserving its view while dismissal completes.
    public func sheet<Item: Hashable, Overlay: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Overlay
    ) -> some View {
        sheet(isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })) {
            if let item = item.wrappedValue { content(item).id(item) }
        }
    }
}

struct FullScreenCoverModifier<WrappedContent: View, Overlay: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let content: WrappedContent
    let isPresented: Binding<Bool>
    let overlay: () -> Overlay
    let style: ViewPresentationTransition.Style

    func buildViewNode(in context: BuildContext) -> ViewNode {
        FullScreenCoverNode(
            contentNode: context.makeNode(from: content),
            content: content,
            isPresented: isPresented,
            overlayBuilder: { inputs in
                let view = overlay()
                return Overlay._makeView(_ViewGraphNode(value: view), inputs: inputs).node
            },
            inputs: context,
            style: style
        )
    }
}

// MARK: - FullScreenCoverNode

final class FullScreenCoverNode: ViewModifierNode, PresentationInputProviding {
    private var isPresented: Binding<Bool>
    private var overlayBuilder: (_ViewInputs) -> ViewNode
    private var overlayNode: ViewNode?
    private var viewInputs: _ViewInputs
    private var style: ViewPresentationTransition.Style
    private(set) lazy var presentation = ViewPresentationTransition(host: self)
    private var overlayBounds: Rect = .zero
    private lazy var dismissAction = DismissAction { [weak self] in
        self?.isPresented.wrappedValue = false
        self?.rebuildOverlay()
    }

    var inspectionChildNodes: [ViewNode] { [contentNode] + presentation.nodes }
    var inputContentNodes: [ViewNode] {
        if !presentation.nodes.isEmpty {
            return overlayNode.map { [$0] } ?? []
        }
        return [contentNode]
    }
    override var transientEnvironmentChildren: [ViewNode] { inspectionChildNodes }

    init<Content: View>(
        contentNode: ViewNode,
        content: Content,
        isPresented: Binding<Bool>,
        overlayBuilder: @escaping (_ViewInputs) -> ViewNode,
        inputs: _ViewInputs,
        style: ViewPresentationTransition.Style = .cover
    ) {
        self.isPresented = isPresented
        self.overlayBuilder = overlayBuilder
        self.viewInputs = inputs
        self.style = style
        super.init(contentNode: contentNode, content: content)
        rebuildOverlay()
    }

    private func rebuildOverlay(refresh: Bool = false) {
        if isPresented.wrappedValue {
            guard overlayNode == nil || refresh else {
                return
            }
            if overlayNode == nil { owner?.deactivateInput(in: contentNode) }
            var inputs = viewInputs
            inputs.environment.dismiss = dismissAction
            let newNode = overlayBuilder(inputs)
            let previous = overlayNode ?? presentation.nodes.last
            if let previous, newNode.canUpdate(previous) {
                previous.update(from: newNode)
                overlayNode = previous
            } else {
                overlayNode = newNode
            }
            overlayNode?.updateEnvironment(inputs.environment)
            presentation.setContent(overlayNode, style: style)
        } else {
            guard overlayNode != nil else {
                return
            }
            overlayNode = nil
            presentation.setContent(nil, style: style)
        }
        invalidateNearestLayer()
        owner?.containerView?.setNeedsDisplay(in: visualAbsoluteFrame())
        performLayout()
    }

    override func performLayout() {
        super.performLayout()
        overlayBounds = Rect(origin: .zero, size: frame.size)
        if style == .sheet, let node = overlayNode ?? presentation.nodes.last {
            let available = Size(width: max(0, min(560, frame.width - 32)), height: max(0, min(600, frame.height - 48)))
            let measured = node.sizeThatFits(ProposedViewSize(available))
            let size = Size(width: max(0, min(available.width, measured.width)), height: max(0, min(available.height, measured.height)))
            overlayBounds = Rect(x: (frame.width - size.width) * 0.5, y: (frame.height - size.height) * 0.5, width: size.width, height: size.height)
        }
        presentation.layout(in: overlayBounds)
    }

    override func updateEnvironment(_ environment: EnvironmentValues) {
        super.updateEnvironment(environment)
        viewInputs.environment = self.environment
        var overlayEnvironment = self.environment
        overlayEnvironment.dismiss = dismissAction
        presentation.nodes.forEach { $0.updateEnvironment(overlayEnvironment) }
    }

    override func updateViewOwner(_ owner: ViewOwner) {
        super.updateViewOwner(owner)
        presentation.nodes.forEach { $0.updateViewOwner(owner) }
    }

    override func draw(with context: UIGraphicsContext) {
        var context = context
        context.environment = environment
        context.translateBy(x: frame.origin.x, y: -frame.origin.y)
        contentNode.draw(with: context)
        guard !presentation.nodes.isEmpty else {
            return
        }
        if style == .sheet, !presentation.entries.isEmpty {
            var backdrop = context
            backdrop.opacity *= 0.35 * (presentation.entries.map { $0.pose.opacity }.max() ?? 0)
            backdrop.drawRect(Rect(origin: .zero, size: frame.size), color: .black)
        }
        // Opacity modals do not move or scale. Preserve backgrounds extending
        // into safe areas instead of masking them to the content viewport.
        presentation.draw(
            with: context,
            in: Rect(origin: .zero, size: frame.size),
            clipsToBounds: style != .fade
        )
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event) else {
            return nil
        }
        if !presentation.nodes.isEmpty {
            // Keep the underlying screen blocked until dismissal has finished.
            return presentation.hitTest(point, event: event, in: Rect(origin: .zero, size: frame.size)) ?? self
        }
        return contentNode.hitTest(contentNode.convert(point, from: self), with: event)
    }

    override func onMouseEvent(_ event: MouseEvent) {
        if presentation.nodes.isEmpty { super.onMouseEvent(event) }
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        if presentation.nodes.isEmpty { super.onTouchesEvent(touches) }
    }

    override func onReceiveEvent(_ event: any InputEvent) {
        if presentation.nodes.isEmpty { super.onReceiveEvent(event) }
    }

    override func update(from newNode: ViewNode) {
        super.update(from: newNode)
        guard let other = newNode as? FullScreenCoverNode else {
            return
        }
        isPresented = other.isPresented
        overlayBuilder = other.overlayBuilder
        style = other.style
        rebuildOverlay(refresh: true)
    }

    override func update(_ deltaTime: TimeInterval) {
        super.update(deltaTime)
        rebuildOverlay()
        presentation.update(deltaTime)
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
            presentation.detach()
        } else {
            presentation.setContent(overlayNode, style: style, animated: false)
        }
    }
}
