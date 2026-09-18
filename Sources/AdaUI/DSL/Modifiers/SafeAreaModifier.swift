//
//  SafeAreaModifier.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 29.03.2026.
//

import AdaInput
import AdaUtils
import Math

extension View {
    /// Expands the view to fill the safe area on the specified edges.
    ///
    /// Use this modifier when a view should extend into the safe area (for example,
    /// a full-bleed background). The view's content will be placed with an expanded
    /// proposal so it physically covers the safe area edges. Child views will see
    /// zeroed insets on the cleared edges.
    ///
    /// - Parameter edges: The edges whose safe area insets are cleared. Defaults to all edges.
    public func ignoresSafeArea(_ edges: Edge.Set = .all) -> some View {
        self.modifier(
            IgnoresSafeAreaModifier(
                content: self,
                edges: edges
            )
        )
    }

    /// Adds extra safe area padding on the specified edges.
    ///
    /// Child views will see their `safeAreaInsets` increased by `length` on
    /// every edge in `edges`. This can be used to reserve space for overlapping
    /// UI elements (such as a floating toolbar).
    ///
    /// - Parameters:
    ///   - edges: The edges to add padding to. Defaults to all edges.
    ///   - length: The amount of padding to add, in points.
    public func safeAreaPadding(_ edges: Edge.Set = .all, _ length: Float) -> some View {
        self.transformEnvironment(\.safeAreaInsets) { insets in
            if edges.contains(.top) {
                insets.top += length
            }
            if edges.contains(.leading) {
                insets.leading += length
            }
            if edges.contains(.bottom) {
                insets.bottom += length
            }
            if edges.contains(.trailing) {
                insets.trailing += length
            }
        }
    }

    /// Adds extra safe area padding using explicit per-edge insets.
    ///
    /// - Parameter insets: The insets to add to the current safe area.
    public func safeAreaPadding(_ insets: EdgeInsets) -> some View {
        self.transformEnvironment(\.safeAreaInsets) { current in
            current.top += insets.top
            current.leading += insets.leading
            current.bottom += insets.bottom
            current.trailing += insets.trailing
        }
    }
}

// MARK: - IgnoresSafeAreaModifier

private struct IgnoresSafeAreaModifier<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let content: Content
    let edges: Edge.Set

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let contentNode = context.makeNode(from: content)
        return IgnoresSafeAreaNode(
            edges: edges,
            contentNode: contentNode,
            content: content,
            inputs: context
        )
    }
}

// MARK: - IgnoresSafeAreaNode

private final class IgnoresSafeAreaNode: ViewNode {
    let edges: Edge.Set
    var contentNode: ViewNode
    private var originalInsets = EdgeInsets()

    init<V: View>(edges: Edge.Set, contentNode: ViewNode, content: V, inputs: _ViewInputs) {
        self.edges = edges
        self.contentNode = contentNode
        super.init(content: content)
        self.contentNode.parent = self
        self.updateEnvironment(inputs.environment)
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        contentNode.sizeThatFits(proposal)
    }

    override func performLayout() {
        let topExp = edges.contains(.top) ? originalInsets.top : 0
        let bottomExp = edges.contains(.bottom) ? originalInsets.bottom : 0
        let leadingExp = edges.contains(.leading) ? originalInsets.leading : 0
        let trailingExp = edges.contains(.trailing) ? originalInsets.trailing : 0

        let expandedW = frame.width + leadingExp + trailingExp
        let expandedH = frame.height + topExp + bottomExp

        contentNode.place(
            in: Point(x: expandedW * 0.5 - leadingExp, y: expandedH * 0.5 - topExp),
            anchor: .center,
            proposal: ProposedViewSize(width: expandedW, height: expandedH)
        )
    }

    override func updateEnvironment(_ environment: EnvironmentValues) {
        originalInsets = environment.safeAreaInsets

        var env = environment
        if edges.contains(.top) {
            env.safeAreaInsets.top = 0
        }
        if edges.contains(.leading) {
            env.safeAreaInsets.leading = 0
        }
        if edges.contains(.bottom) {
            env.safeAreaInsets.bottom = 0
        }
        if edges.contains(.trailing) {
            env.safeAreaInsets.trailing = 0
        }

        let prevVersion = self.environment.version
        super.updateEnvironment(env)
        guard self.environment.version != prevVersion else {
            return
        }
        contentNode.updateEnvironment(self.environment)
    }

    override func draw(with context: UIGraphicsContext) {
        var ctx = context
        ctx.environment = environment
        ctx.translateBy(x: frame.origin.x, y: -frame.origin.y)
        contentNode.draw(with: ctx)
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        let newPoint = contentNode.convert(point, from: self)
        return contentNode.hitTest(newPoint, with: event)
    }

    override func update(_ deltaTime: TimeInterval) {
        contentNode.update(deltaTime)
    }

    override func updateViewOwner(_ owner: ViewOwner) {
        super.updateViewOwner(owner)
        contentNode.updateViewOwner(owner)
    }

    override func update(from newNode: ViewNode) {
        super.update(from: newNode)
        guard let other = newNode as? IgnoresSafeAreaNode else {
            return
        }
        contentNode.update(from: other.contentNode)
        contentNode.parent = self
    }
}
