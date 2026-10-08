//
//  UIKitViewRepresentable.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 21.04.2026.
//

#if canImport(UIKit) && (os(iOS) || os(tvOS) || os(visionOS))
    import AdaUtils
    import Math
    import UIKit

    /// A context for a UIKitViewRepresentable.
    public struct UIKitViewRepresentableContext<View: UIKitViewRepresentable> {
        /// The environment for the UIKitViewRepresentable.
        public internal(set) var environment: EnvironmentValues

        /// The coordinator for the UIKitViewRepresentable.
        public internal(set) var coordinator: View.Coordinator
    }

    /// A wrapper for a UIKit view that you use to integrate that view into your AdaUI view hierarchy.
    @MainActor
    public protocol UIKitViewRepresentable: View {
        /// The type of the view.
        associatedtype UIViewType: UIKit.UIView

        /// The type of the coordinator.
        associatedtype Coordinator = Void

        /// The context for the UIKitViewRepresentable.
        typealias Context = UIKitViewRepresentableContext<Self>

        /// Make a UIView.
        ///
        /// - Parameter context: The context.
        /// - Returns: The UIView.
        func makeUIView(context: Context) -> UIViewType

        /// Update a UIView.
        ///
        func updateUIView(_ uiView: UIViewType, in context: Context)

        /// The size that fits the UIKitViewRepresentable.
        ///
        /// - Parameter proposal: The proposed size.
        /// - Parameter uiView: The view.
        /// - Parameter context: The context.
        /// - Returns: The size that fits the UIKitViewRepresentable.
        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView: UIViewType,
            context: Context
        ) -> Size

        /// Make a coordinator.
        ///
        /// - Returns: The coordinator.
        func makeCoordinator() -> Coordinator

        /// Cleans up the UIKit view and coordinator before removal.
        static func dismantleUIView(_ uiView: UIViewType, coordinator: Coordinator)
    }

    extension UIKitViewRepresentable where Coordinator == Void {
        /// Make a coordinator.
        ///
        /// - Returns: The coordinator.
        public func makeCoordinator() {
            return
        }
    }

    extension UIKitViewRepresentable {
        public static func dismantleUIView(_ uiView: UIViewType, coordinator: Coordinator) {
            _ = uiView
            _ = coordinator
        }

        /// The size that fits the UIKitViewRepresentable.
        ///
        /// - Parameter proposal: The proposed size.
        /// - Parameter uiView: The view.
        /// - Parameter context: The context.
        /// - Returns: The size that fits the UIKitViewRepresentable.
        public func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView: UIViewType,
            context _: Context
        ) -> Size {
            let size = uiView.systemLayoutSizeFitting(
                proposal.replacingUnspecifiedDimensions().toCGSize,
                withHorizontalFittingPriority: UIKit.UILayoutPriority.defaultLow,
                verticalFittingPriority: UIKit.UILayoutPriority.defaultLow
            )
            return Size(width: Float(size.width), height: Float(size.height))
        }
    }

    extension UIKitViewRepresentable {
        /// The body of the UIKitViewRepresentable.
        ///
        /// - Returns: The body of the UIKitViewRepresentable.
        public var body: some View {
            UIKitViewRepresentableView(representable: self)
        }
    }

    /// A view that represents a UIKitViewRepresentable.
    struct UIKitViewRepresentableView<Representable: UIKitViewRepresentable>: View, ViewNodeBuilder {
        typealias Body = Never
        let representable: Representable

        func buildViewNode(in context: BuildContext) -> ViewNode {
            let node = NativeViewHostNode(
                representable: self,
                content: self
            )

            node.updateEnvironment(context.environment)

            return node
        }
    }

#endif
