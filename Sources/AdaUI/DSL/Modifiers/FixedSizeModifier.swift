//
//  FixedSizeModifier.swift
//  AdaEngine
//
//  Created by OpenAI on 29.04.2026.
//

import Math

extension View {
    /// Fixes this view at its ideal size.
    public func fixedSize() -> some View {
        fixedSize(horizontal: true, vertical: true)
    }

    /// Fixes this view at its ideal size in the specified dimensions.
    public func fixedSize(horizontal: Bool, vertical: Bool) -> some View {
        modifier(
            FixedSizeModifier(
                content: self,
                horizontal: horizontal,
                vertical: vertical
            )
        )
    }
}

struct FixedSizeModifier<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let content: Content
    let horizontal: Bool
    let vertical: Bool

    func buildViewNode(in context: BuildContext) -> ViewNode {
        FixedSizeViewNode(
            horizontal: horizontal,
            vertical: vertical,
            contentNode: context.makeNode(from: content),
            content: content
        )
    }
}

final class FixedSizeViewNode: ViewModifierNode {
    private var horizontal: Bool
    private var vertical: Bool

    init<Content: View>(
        horizontal: Bool,
        vertical: Bool,
        contentNode: ViewNode,
        content: Content
    ) {
        self.horizontal = horizontal
        self.vertical = vertical
        super.init(contentNode: contentNode, content: content)
    }

    override func update(from newNode: ViewNode) {
        guard let other = newNode as? FixedSizeViewNode else {
            super.update(from: newNode)
            return
        }

        if self.horizontal != other.horizontal || self.vertical != other.vertical {
            Self.recordLayoutMutationRequiringAncestorPass()
            self.markNeedsLayout()
        }
        self.horizontal = other.horizontal
        self.vertical = other.vertical
        super.update(from: newNode)
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        contentNode.sizeThatFits(
            ProposedViewSize(
                width: horizontal ? nil : proposal.width,
                height: vertical ? nil : proposal.height
            )
        )
    }
}
