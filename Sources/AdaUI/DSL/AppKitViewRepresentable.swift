//
//  AppKitViewRepresentable.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 21.04.2026.
//

#if canImport(AppKit) && os(macOS)
    import AdaUtils
    import AppKit
    import Math

    /// A context for an AppKitViewRepresentable.
    public struct AppKitViewRepresentableContext<View: AppKitViewRepresentable> {
        /// The environment for the AppKitViewRepresentable.
        public internal(set) var environment: EnvironmentValues

        /// The coordinator for the AppKitViewRepresentable.
        public internal(set) var coordinator: View.Coordinator
    }

    /// A wrapper for an AppKit view that you use to integrate that view into your AdaUI view hierarchy.
    @MainActor
    public protocol AppKitViewRepresentable: View {
        /// The type of the view.
        associatedtype NSViewType: NSView

        /// The type of the coordinator.
        associatedtype Coordinator = Void

        /// The context for the AppKitViewRepresentable.
        typealias Context = AppKitViewRepresentableContext<Self>

        /// Make an NSView.
        ///
        /// - Parameter context: The context.
        /// - Returns: The NSView.
        func makeNSView(context: Context) -> NSViewType

        /// Update an NSView.
        ///
        func updateNSView(_ nsView: NSViewType, context: Context)

        /// The size that fits the AppKitViewRepresentable.
        ///
        /// - Parameter proposal: The proposed size.
        /// - Parameter nsView: The view.
        /// - Parameter context: The context.
        /// - Returns: The size that fits the AppKitViewRepresentable.
        func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView: NSViewType,
            context: Context
        ) -> Size

        /// Make a coordinator.
        ///
        /// - Returns: The coordinator.
        func makeCoordinator() -> Coordinator

        /// Cleans up the AppKit view and coordinator before removal.
        static func dismantleNSView(_ nsView: NSViewType, coordinator: Coordinator)
    }

    extension AppKitViewRepresentable where Coordinator == Void {
        /// Make a coordinator.
        ///
        /// - Returns: The coordinator.
        public func makeCoordinator() {
            return
        }
    }

    extension AppKitViewRepresentable {
        public static func dismantleNSView(_ nsView: NSViewType, coordinator: Coordinator) {
            _ = nsView
            _ = coordinator
        }

        /// The size that fits the AppKitViewRepresentable.
        ///
        /// - Parameter proposal: The proposed size.
        /// - Parameter nsView: The view.
        /// - Parameter context: The context.
        /// - Returns: The size that fits the AppKitViewRepresentable.
        public func sizeThatFits(
            _: ProposedViewSize,
            nsView: NSViewType,
            context _: Context
        ) -> Size {
            let fittingSize = nsView.fittingSize
            return Size(width: Float(fittingSize.width), height: Float(fittingSize.height))
        }
    }

    extension AppKitViewRepresentable {
        /// The body of the AppKitViewRepresentable.
        ///
        /// - Returns: The body of the AppKitViewRepresentable.
        public var body: some View {
            AppKitViewRepresentableView(representable: self)
        }
    }

    /// A view that represents an AppKitViewRepresentable.
    struct AppKitViewRepresentableView<Representable: AppKitViewRepresentable>: View, ViewNodeBuilder {
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
