//
//  FrameModifier.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 08.06.2024.
//

import Math

extension View {
    /// Positions this view within an invisible frame with the specified size.
    /// - Parameter width: A fixed width for the resulting view. If width is nil, the resulting view assumes this view’s sizing behavior.
    /// - Parameter height: A fixed height for the resulting view. If height is nil, the resulting view assumes this view’s sizing behavior.
    /// - Returns: A view with fixed dimensions of width and height, for the parameters that are non-nil.
    public func frame(width: Float? = nil, height: Float? = nil, alignment: Alignment = .center) -> some View {
        self.modifier(
            _FrameViewModifier(
                content: self,
                frame: .size(width: width, height: height, alignment: alignment)
            )
        )
    }

    /// Positions this view within an invisible frame having the specified size constraints.
    ///
    /// Behavior follows SwiftUI: `min`/`max` bound the measured size along each axis; `ideal` fills in when the parent proposal is unspecified.
    /// Pass `nil` for a bound to leave that bound open (maximum uses infinity when omitted).
    public func frame(
        minWidth: Float? = nil,
        idealWidth: Float? = nil,
        maxWidth: Float? = nil,
        minHeight: Float? = nil,
        idealHeight: Float? = nil,
        maxHeight: Float? = nil,
        alignment: Alignment = .center
    ) -> some View {
        self.modifier(
            _FrameViewModifier(
                content: self,
                frame: .constraints(
                    minWidth: minWidth,
                    idealWidth: idealWidth,
                    maxWidth: maxWidth,
                    minHeight: minHeight,
                    idealHeight: idealHeight,
                    maxHeight: maxHeight,
                    alignment: alignment
                )
            )
        )
    }
}

struct _FrameViewModifier<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never
    let content: Content

    let frame: FrameViewNode.Frame

    func buildViewNode(in context: BuildContext) -> ViewNode {
        FrameViewNode(
            frameRule: frame,
            content: content,
            contentNode: context.makeNode(from: content)
        )
    }
}

final class FrameViewNode: ViewModifierNode {
    override var allowsNestedFrameAnimation: Bool {
        true
    }

    enum Frame: Equatable {
        case size(width: Float?, height: Float?, alignment: Alignment)
        case constraints(
            minWidth: Float?,
            idealWidth: Float?,
            maxWidth: Float?,
            minHeight: Float?,
            idealHeight: Float?,
            maxHeight: Float?,
            alignment: Alignment
        )
    }

    private(set) var frameRule: Frame

    init<Content: View>(frameRule: Frame, content: Content, contentNode: ViewNode) {
        self.frameRule = frameRule
        super.init(contentNode: contentNode, content: content)
    }

    override func update(from newNode: ViewNode) {
        guard let other = newNode as? FrameViewNode else {
            super.update(from: newNode)
            return
        }
        if self.frameRule != other.frameRule {
            Self.recordLayoutMutationRequiringAncestorPass()
            self.markNeedsLayout()
        }
        self.frameRule = other.frameRule
        super.update(from: newNode)
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        switch frameRule {
        case let .size(width, height, _):
            var newSize = self.contentNode.sizeThatFits(
                ProposedViewSize(
                    width: width ?? proposal.width,
                    height: height ?? proposal.height
                )
            )
            if let width {
                newSize.width = width
            }

            if let height {
                newSize.height = height
            }

            return newSize

        case let .constraints(minW, idealW, maxW, minH, idealH, maxH, _):
            if Self.isOpenConstraints(
                minWidth: minW,
                idealWidth: idealW,
                maxWidth: maxW,
                minHeight: minH,
                idealHeight: idealH,
                maxHeight: maxH
            ) {
                return self.contentNode.sizeThatFits(proposal)
            }

            let childProposal = ProposedViewSize(
                width: Self.resolvedProposalDimension(
                    parent: proposal.width,
                    min: minW,
                    ideal: idealW,
                    maxBound: maxW
                ),
                height: Self.resolvedProposalDimension(
                    parent: proposal.height,
                    min: minH,
                    ideal: idealH,
                    maxBound: maxH
                )
            )

            var measured = self.contentNode.sizeThatFits(childProposal)
            measured.width = Self.clampAxis(
                measured.width,
                min: minW,
                maxBound: maxW
            )
            measured.height = Self.clampAxis(
                measured.height,
                min: minH,
                maxBound: maxH
            )

            measured.width = Self.expandFlexibleAxis(
                measured.width,
                maxBound: maxW,
                parentCap: proposal.width
            )
            measured.height = Self.expandFlexibleAxis(
                measured.height,
                maxBound: maxH,
                parentCap: proposal.height
            )
            return measured
        }
    }

    override func performLayout() {
        switch frameRule {
        case let .size(_, _, alignment):
            let alignment = alignment.resolved(for: environment.layoutDirection)
            let proposal = ProposedViewSize(self.frame.size)
            let origin = Self.placementOrigin(container: self.frame.size, alignment: alignment)
            self.contentNode.place(
                in: origin,
                anchor: alignment.anchorPoint,
                proposal: proposal
            )
        case let .constraints(_, _, _, _, _, _, alignment):
            if Self.isOpenConstraintsFromFrame(frameRule) {
                super.performLayout()
                return
            }
            let alignment = alignment.resolved(for: environment.layoutDirection)
            let proposal = ProposedViewSize(self.frame.size)
            let origin = Self.placementOrigin(container: self.frame.size, alignment: alignment)
            self.contentNode.place(
                in: origin,
                anchor: alignment.anchorPoint,
                proposal: proposal
            )
        }
    }

    private static func isOpenConstraintsFromFrame(_ frame: Frame) -> Bool {
        guard case let .constraints(minW, idealW, maxW, minH, idealH, maxH, _) = frame else {
            return false
        }
        return isOpenConstraints(
            minWidth: minW,
            idealWidth: idealW,
            maxWidth: maxW,
            minHeight: minH,
            idealHeight: idealH,
            maxHeight: maxH
        )
    }

    private static func isOpenConstraints(
        minWidth: Float?,
        idealWidth: Float?,
        maxWidth: Float?,
        minHeight: Float?,
        idealHeight: Float?,
        maxHeight: Float?
    ) -> Bool {
        minWidth == nil && idealWidth == nil && maxWidth == nil
            && minHeight == nil && idealHeight == nil && maxHeight == nil
    }

    /// Builds a concrete proposal for the child along one axis.
    private static func resolvedProposalDimension(
        parent: Float?,
        min: Float?,
        ideal: Float?,
        maxBound: Float?
    ) -> Float? {
        let minV = min ?? 0
        let maxV: Float
        if let maxBound {
            maxV = maxBound.isFinite ? maxBound : .infinity
        } else {
            maxV = .infinity
        }
        guard let base = parent ?? ideal else {
            return nil
        }

        var v = Swift.max(base, minV)
        if maxV.isFinite {
            v = Swift.min(v, maxV)
        }
        return v.isFinite ? v : .infinity
    }

    private static func clampAxis(
        _ value: Float,
        min: Float?,
        maxBound: Float?
    ) -> Float {
        var v = value
        if let min {
            v = Swift.max(v, min)
        }
        if let maxBound, maxBound.isFinite {
            v = Swift.min(v, maxBound)
        }
        return v
    }

    /// SwiftUI-style flexible frame: `maxWidth: .infinity` / `maxHeight: .infinity`
    /// should expand the frame to the parent's finite proposal.
    private static func expandFlexibleAxis(
        _ value: Float,
        maxBound: Float?,
        parentCap: Float?
    ) -> Float {
        guard let maxBound, !maxBound.isFinite else {
            return value
        }

        guard let parentCap else {
            return value
        }

        if parentCap == .infinity {
            return .infinity
        }

        if parentCap.isFinite {
            return parentCap
        }

        return value
    }

    private static func placementOrigin(container: Size, alignment: Alignment) -> Point {
        let x: Float =
            switch alignment.horizontal {
            case .leading: 0
            case .center: container.width * 0.5
            case .trailing: container.width
            }
        let y: Float =
            switch alignment.vertical {
            case .top: 0
            case .center: container.height * 0.5
            case .bottom: container.height
            }
        return Point(x: x, y: y)
    }
}
