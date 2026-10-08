//
//  UIViewRepresentable.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 09.06.2024.
//

import AdaUtils
import Math

/// A context for a UIViewRepresentable.
public struct UIViewRepresentableContext<View: UIViewRepresentable> {
    /// The environment for the UIViewRepresentable.
    public internal(set) var environment: EnvironmentValues

    /// The coordinator for the UIViewRepresentable.
    public internal(set) var coordinator: View.Coordinator
}

/// A wrapper for a UIView that you use to integrate that view into your DSL view hierarchy.
///
/// - Warning: DSL views fully control the UIView's center, bounds, frame, and transform. Don't set
///   those properties directly on a managed view because that conflicts with AdaUI layout.
@MainActor
public protocol UIViewRepresentable: View {
    /// The type of the view.
    associatedtype ViewType: UIView

    /// The type of the coordinator.
    associatedtype Coordinator = Void

    /// The context for the UIViewRepresentable.
    typealias Context = UIViewRepresentableContext<Self>

    /// Make a UIView.
    ///
    /// - Parameter context: The context.
    /// - Returns: The UIView.
    func makeUIView(in context: Context) -> ViewType

    /// Update a UIView.
    ///
    func updateUIView(_ view: ViewType, in context: Context)

    /// The size that fits the UIViewRepresentable.
    ///
    /// - Parameter proposal: The proposed size.
    /// - Parameter view: The view.
    /// - Parameter context: The context.
    /// - Returns: The size that fits the UIViewRepresentable.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        view: ViewType,
        context: Context
    ) -> Size

    /// Make a coordinator.
    ///
    /// - Returns: The coordinator.
    func makeCoordinator() -> Coordinator
}

extension UIViewRepresentable where Coordinator == Void {
    /// Make a coordinator.
    ///
    /// - Returns: The coordinator.
    public func makeCoordinator() {
        return
    }
}

extension UIViewRepresentable {
    /// The size that fits the UIViewRepresentable.
    ///
    /// - Parameter proposal: The proposed size.
    /// - Parameter view: The view.
    /// - Parameter context: The context.
    /// - Returns: The size that fits the UIViewRepresentable.
    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        view: ViewType,
        context _: Context
    ) -> Size {
        return view.sizeThatFits(proposal)
    }
}

extension UIViewRepresentable {
    /// The body of the UIViewRepresentable.
    ///
    /// - Returns: The body of the UIViewRepresentable.
    public var body: some View {
        UIViewRepresentableView(repsentable: self)
    }
}

/// A view that represents a UIViewRepresentable.
struct UIViewRepresentableView<Representable: UIViewRepresentable>: View, ViewNodeBuilder {
    typealias Body = Never
    let repsentable: Representable

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let node = UIViewRepresentableNode(
            representable: repsentable,
            content: self
        )

        node.updateEnvironment(context.environment)

        return node
    }
}
