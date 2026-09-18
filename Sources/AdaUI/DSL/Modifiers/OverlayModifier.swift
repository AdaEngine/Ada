//
//  OverlayModifier.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 01.07.2024.
//

import AdaAnimation
import Math

extension View {
    /// Layers the views that you specify in front of this view.
    /// - Parameter anchor: The anchor that the modifier uses to position the implicit ``ZStack`` that groups the foreground views. The default is center.
    /// - Parameter content: A ``ViewBuilder`` that you use to declare the views to draw in front of this view,
    /// stacked in the order that you list them. The last view that you list appears at the front of the stack.
    public func overlay<Content: View>(
        anchor: AnchorPoint = .center,
        @ViewBuilder content: () -> Content
    ) -> some View {
        self.modifier(
            OverlayViewModifier(
                anchor: anchor,
                content: self,
                overlayContent: content()
            )
        )
    }
}

private struct OverlayViewModifier<Content: View, OverlayContent: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let anchor: AnchorPoint
    let content: Content
    let overlayContent: OverlayContent

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let contentNode = context.makeNode(from: content)
        let overlayNode = context.makeNode(from: overlayContent)

        return LayoutViewContainerNode(
            layout: OverlayLayout(anchor: anchor),
            content: content,
            nodes: [contentNode, overlayNode]
        )
    }
}

private struct OverlayLayout: Layout {
    typealias AnimatableData = EmptyAnimatableData

    let anchor: AnchorPoint

    func sizeThatFits(_ proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) -> Size {
        guard !subviews.isEmpty else {
            return proposal.replacingUnspecifiedDimensions()
        }

        let contentSubview = subviews[0]
        return contentSubview.sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: Rect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout Void) {
        guard !subviews.isEmpty else {
            return
        }

        let contentSubview = subviews[0]
        let contentProposal = ProposedViewSize(bounds.size)
        let center = Point(x: bounds.midX, y: bounds.midY)
        contentSubview.place(at: center, anchor: .center, proposal: contentProposal)

        guard subviews.count > 1 else {
            return
        }

        let overlayOrigin = Point(
            x: bounds.minX + bounds.width * anchor.x,
            y: bounds.minY + bounds.height * anchor.y
        )

        for index in 1..<subviews.count {
            subviews[index].place(at: overlayOrigin, anchor: anchor, proposal: contentProposal)
        }
    }
}
