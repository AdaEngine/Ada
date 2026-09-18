//
//  Layout.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 22.06.2024.
//

import AdaAnimation
import Math

/// Layout-specific properties of a layout container.
public struct LayoutProperties: Equatable {
    /// The orientation of the containing stack-like container.
    var stackOrientation: Axis?

    public init(stackOrientation: Axis? = nil) {
        self.stackOrientation = stackOrientation
    }
}

/// A protocol that defines a layout for views.
@MainActor
@preconcurrency
public protocol Layout: Animatable {
    /// The cache of the layout.
    associatedtype Cache = Void

    /// The subviews of the layout.
    typealias Subviews = LayoutSubviews

    /// The size that fits the layout.
    ///
    /// - Parameters:
    ///   - proposal: The proposed size.
    ///   - subviews: The subviews.
    ///   - cache: The cache.
    /// - Returns: The size that fits the layout.
    func sizeThatFits(_ proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> Size

    /// Place the subviews in the layout.
    ///
    /// - Parameters:
    ///   - bounds: The bounds.
    ///   - proposal: The proposed size.
    ///   - subviews: The subviews.
    ///   - cache: The cache.
    func placeSubviews(in bounds: Rect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache)

    /// Update the cache of the layout.
    ///
    /// - Parameters:
    ///   - cache: The cache.
    ///   - subviews: The subviews.
    func updateCache(_ cache: inout Cache, subviews: Subviews)

    /// Make the cache of the layout.
    ///
    /// - Parameters:
    ///   - subviews: The subviews.
    /// - Returns: The cache.
    func makeCache(subviews: Subviews) -> Cache

    /// Properties of a layout container.
    static var layoutProperties: LayoutProperties { get }
}

extension Layout {
    public func updateCache(_: inout Cache, subviews _: Subviews) {}

    public static var layoutProperties: LayoutProperties { LayoutProperties() }
}

extension Layout where Cache == Void {
    public func makeCache(subviews _: Subviews) -> Cache {
        return
    }
}

extension Layout {
    /// Call the layout as a function.
    ///
    /// - Parameter content: The content of the layout.
    /// - Returns: The layout.
    public func callAsFunction<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        CustomLayoutContainer(layout: self, content: content)
    }
}

// MARK: - Internal

struct CustomLayoutContainer<T: Layout, Content: View>: View {
    typealias Body = Never

    let layout: T
    let content: () -> Content

    public static func _makeView(_ view: _ViewGraphNode<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let content = view[\.content]
        let layout = AnyLayout(view[\.layout].value)

        var inputs = inputs
        inputs.layout = layout
        let node = ObservedLayoutViewContainerNode(layout: layout, content: content.value)
        node.updateEnvironment(inputs.environment)
        node.invalidateContent()
        return _ViewOutputs(node: node)
    }
}
