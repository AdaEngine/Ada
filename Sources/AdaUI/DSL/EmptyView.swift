//
//  EmptyView.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 22.06.2024.
//

import Math

/// A view that doesn’t contain any content.
public struct EmptyView: View, ViewNodeBuilder {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    /// Creates an empty view.
    public init() {}

    func buildViewNode(in _: BuildContext) -> ViewNode {
        EmptyViewNode(content: self)
    }
}

final class EmptyViewNode: ViewNode {
    override func sizeThatFits(_: ProposedViewSize) -> Size {
        return .zero
    }
}
