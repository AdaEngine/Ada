//
//  Divider.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 04.08.2024.
//

import AdaUtils
import Math

/// A view that draws a divider.
public struct Divider: View, ViewNodeBuilder {
    /// Initialize a new divider.
    public init() {}

    /// The body of the divider.
    public var body: Never {
        fatalError("Unreachable code")
    }

    /// Build a view node.
    ///
    /// - Parameter context: The build context.
    /// - Returns: The view node.
    func buildViewNode(in _: BuildContext) -> ViewNode {
        return DividerNode(content: self)
    }
}

/// A node that draws a divider.
final class DividerNode: ViewNode {
    /// Draw the divider.
    ///
    /// - Parameter context: The graphics context.
    override func draw(with context: UIGraphicsContext) {
        var newContext = context
        newContext.translateBy(x: self.frame.origin.x, y: -self.frame.origin.y)

        let rect: Rect
        if layoutProperties.stackOrientation == .horizontal {
            rect = Rect(
                origin: .zero,
                size: Size(width: 1, height: frame.height)
            )
        } else {
            rect = Rect(
                origin: .zero,
                size: Size(width: frame.width, height: 1)
            )
        }

        newContext.drawRect(
            rect,
            color: .gray
        )

        super.draw(with: context)
    }

    /// Calculate the size that fits the proposal.
    ///
    /// - Parameter proposal: The proposed view size.
    /// - Returns: The size that fits the proposal.
    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        if proposal == .zero {
            if layoutProperties.stackOrientation == .horizontal {
                return Size(width: 1, height: 0)
            }

            return Size(width: 0, height: 1)
        }

        if layoutProperties.stackOrientation == .horizontal {
            let height = max(proposal.height ?? 0, 0)
            return Size(width: 1, height: height)
        }

        let width = max(proposal.width ?? 0, 0)
        return Size(width: width, height: 1)
    }
}
