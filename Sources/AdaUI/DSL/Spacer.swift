//
//  Spacer.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 24.06.2024.
//

import Math

/// A flexible space that expands along the major axis of its containing stack layout,
/// or on both axes if not contained in a stack.
public struct Spacer: View, ViewNodeBuilder {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    /// The minimum length this spacer can be shrunk to, along the axis or axes of expansion.
    public var minLength: Float?

    public init(minLength: Float? = nil) {
        self.minLength = minLength
    }

    func buildViewNode(in _: BuildContext) -> ViewNode {
        SpacerViewNode(minLength: minLength, content: self)
    }
}

final class SpacerViewNode: ViewNode {
    let minLength: Float?

    init(minLength: Float?, content: Spacer) {
        self.minLength = minLength
        super.init(content: content)
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        let minLength = self.minLength ?? 8

        switch layoutProperties.stackOrientation {
        case .horizontal:
            let width = max(proposal.width ?? minLength, minLength)
            return Size(width: width, height: 0)
        case .vertical:
            let height = max(proposal.height ?? minLength, minLength)
            return Size(width: 0, height: height)
        default:
            let width = max(proposal.width ?? minLength, minLength)
            let height = max(proposal.height ?? minLength, minLength)
            return Size(width: width, height: height)
        }
    }
}
