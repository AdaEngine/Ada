//
//  AspectRatioModifier.swift
//  AdaEngine
//
//  Created by OpenAI on 08.05.2026.
//

import Math

/// A mode that specifies how content fits into available space.
public enum ContentMode: Equatable, Hashable, Sendable {
    /// Resize the content so it all fits within the available space.
    case fit
    /// Resize the content so it fills the available space.
    case fill
}

extension View {
    /// Constrains this view's dimensions to the specified aspect ratio.
    ///
    /// - Parameters:
    ///   - aspectRatio: The width-to-height ratio to use. Pass `nil` to use the view's ideal aspect ratio.
    ///   - contentMode: The scaling behavior used to fit or fill the parent proposal.
    /// - Returns: A view that constrains this view's dimensions to the aspect ratio.
    public func aspectRatio(_ aspectRatio: Float? = nil, contentMode: ContentMode) -> some View {
        modifier(
            AspectRatioViewModifier(
                aspectRatio: aspectRatio,
                contentMode: contentMode,
                content: self
            )
        )
    }

    /// Scales this view to fit its parent.
    ///
    /// This is equivalent to calling `aspectRatio(nil, contentMode: .fit)`.
    public func scaledToFit() -> some View {
        aspectRatio(contentMode: .fit)
    }

    /// Scales this view to fill its parent.
    ///
    /// This is equivalent to calling `aspectRatio(nil, contentMode: .fill)`.
    public func scaledToFill() -> some View {
        aspectRatio(contentMode: .fill)
    }
}

struct AspectRatioViewModifier<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let aspectRatio: Float?
    let contentMode: ContentMode
    let content: Content

    func buildViewNode(in context: BuildContext) -> ViewNode {
        AspectRatioViewNode(
            aspectRatio: aspectRatio,
            contentMode: contentMode,
            contentNode: context.makeNode(from: content),
            content: content
        )
    }
}

final class AspectRatioViewNode: ViewModifierNode {
    private var aspectRatio: Float?
    private var contentMode: ContentMode

    init<Content: View>(
        aspectRatio: Float?,
        contentMode: ContentMode,
        contentNode: ViewNode,
        content: Content
    ) {
        self.aspectRatio = aspectRatio
        self.contentMode = contentMode
        super.init(contentNode: contentNode, content: content)
    }

    override func update(from newNode: ViewNode) {
        guard let other = newNode as? AspectRatioViewNode else {
            super.update(from: newNode)
            return
        }

        if self.aspectRatio != other.aspectRatio || self.contentMode != other.contentMode {
            Self.recordLayoutMutationRequiringAncestorPass()
            self.markNeedsLayout()
        }
        self.aspectRatio = other.aspectRatio
        self.contentMode = other.contentMode
        super.update(from: newNode)
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        guard let proposal = aspectProposal(for: proposal) else {
            return contentNode.sizeThatFits(proposal)
        }

        return contentNode.sizeThatFits(proposal)
    }

    override func performLayout() {
        guard let proposal = aspectProposal(for: ProposedViewSize(frame.size)) else {
            super.performLayout()
            return
        }

        let childSize = contentNode.sizeThatFits(proposal)
        contentNode.place(
            in: Point(x: frame.width * 0.5, y: frame.height * 0.5),
            anchor: .center,
            proposal: proposal,
            measuredSize: childSize
        )
    }

    private func aspectProposal(for proposal: ProposedViewSize) -> ProposedViewSize? {
        let idealSize = contentNode.sizeThatFits(.unspecified)
        let ratio = resolvedAspectRatio(from: idealSize)

        guard ratio > 0, ratio.isFinite else {
            return nil
        }

        guard
            let constrainedSize = Self.constrainedSize(
                for: proposal,
                fallback: idealSize,
                aspectRatio: ratio,
                contentMode: contentMode
            )
        else {
            return .unspecified
        }

        return ProposedViewSize(constrainedSize)
    }

    private func resolvedAspectRatio(from idealSize: Size) -> Float {
        if let aspectRatio {
            return aspectRatio
        }

        guard idealSize.width > 0, idealSize.height > 0 else {
            return 0
        }

        return idealSize.width / idealSize.height
    }

    private static func constrainedSize(
        for proposal: ProposedViewSize,
        fallback: Size,
        aspectRatio: Float,
        contentMode: ContentMode
    ) -> Size? {
        let width = finiteDimension(proposal.width)
        let height = finiteDimension(proposal.height)

        switch (width, height) {
        case let (.some(width), .some(height)):
            let widthFromHeight = height * aspectRatio

            switch contentMode {
            case .fit:
                if widthFromHeight <= width {
                    return Size(width: widthFromHeight, height: height)
                }
                return Size(width: width, height: width / aspectRatio)

            case .fill:
                if widthFromHeight >= width {
                    return Size(width: widthFromHeight, height: height)
                }
                return Size(width: width, height: width / aspectRatio)
            }

        case (.some(let width), nil):
            return Size(width: width, height: width / aspectRatio)

        case (nil, let .some(height)):
            return Size(width: height * aspectRatio, height: height)

        case (nil, nil):
            return constrainedSize(
                for: ProposedViewSize(fallback),
                fallback: .zero,
                aspectRatio: aspectRatio,
                contentMode: contentMode
            )
        }
    }

    private static func finiteDimension(_ value: Float?) -> Float? {
        guard let value, value.isFinite else {
            return nil
        }

        return max(value, 0)
    }
}
