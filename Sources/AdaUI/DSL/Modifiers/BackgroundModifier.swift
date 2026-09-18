//
//  BackgroundModifier.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 24.06.2024.
//

import AdaAnimation
import AdaUtils
import Math

extension View {
    /// Layers the color view that you specify behind this view.
    /// - Parameter color: A ``Color`` that you use to declare the views to draw behind this view.
    public func background(_ color: Color) -> some View {
        self.modifier(
            BackgroundViewModifier(
                anchor: .center,
                backgroundContent: color,
                content: self
            )
        )
    }

    /// Layers the views that you specify behind this view.
    /// - Parameter anchor: The alignment that the modifier uses to position the implicit ``ZStack`` that groups the background views. The default is center.
    /// - Parameter content: A ``ViewBuilder`` that you use to declare the views to draw behind this view,
    /// stacked in a cascading order from bottom to top. The last view that you list appears at the front of the stack.
    public func background<Content: View>(anchor: AnchorPoint = .center, @ViewBuilder content: () -> Content) -> some View {
        self.modifier(
            BackgroundViewModifier(
                anchor: anchor,
                backgroundContent: content(),
                content: self
            )
        )
    }

    /// Layers the views that you specify behind this view.
    /// - Parameter anchor: The alignment that the modifier uses to position the implicit ``ZStack`` that groups the background views. The default is center.
    /// - Parameter content: A ``ViewBuilder`` that you use to declare the views to draw behind this view,
    /// stacked in a cascading order from bottom to top. The last view that you list appears at the front of the stack.
    public func background<Content: View>(anchor: AnchorPoint = .center, _ content: @autoclosure () -> Content) -> some View {
        self.modifier(
            BackgroundViewModifier(
                anchor: anchor,
                backgroundContent: content(),
                content: self
            )
        )
    }
}

private struct BackgroundViewModifier<Content: View, BackgroundContent: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let anchor: AnchorPoint
    let backgroundContent: BackgroundContent
    let content: Content

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let backgroundNode = context.makeNode(from: backgroundContent)
        let contentNode = context.makeNode(from: content)

        return LayoutViewContainerNode(
            layout: BackgroundLayout(anchor: anchor),
            content: content,
            nodes: [backgroundNode, contentNode]
        )
    }
}

private struct BackgroundLayout: Layout {
    typealias AnimatableData = EmptyAnimatableData

    let anchor: AnchorPoint

    func sizeThatFits(_ proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) -> Size {
        guard !subviews.isEmpty else {
            return proposal.replacingUnspecifiedDimensions()
        }

        let contentSubview = subviews[subviews.count - 1]
        return contentSubview.sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: Rect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout Void) {
        guard !subviews.isEmpty else {
            return
        }

        let contentSubview = subviews[subviews.count - 1]
        let contentProposal = ProposedViewSize(bounds.size)
        let center = Point(x: bounds.midX, y: bounds.midY)

        // The modified view defines the resulting size.
        contentSubview.place(at: center, anchor: AnchorPoint.center, proposal: contentProposal)

        guard subviews.count > 1 else {
            return
        }

        let backgroundOrigin = Point(
            x: bounds.minX + bounds.width * anchor.x,
            y: bounds.minY + bounds.height * anchor.y
        )

        for index in 0..<(subviews.count - 1) {
            subviews[index].place(at: backgroundOrigin, anchor: anchor, proposal: contentProposal)
        }
    }
}
