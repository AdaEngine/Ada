//
//  SwiftUIViewRepresentable.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 21.04.2026.
//

#if canImport(SwiftUI)
    import AdaUtils
    import Math
    import SwiftUI

    /// A wrapper for a SwiftUI view that you use to integrate that view into your AdaUI view hierarchy.
    @MainActor
    public struct SwiftUIViewRepresentable<Content: SwiftUI.View>: View, ViewNodeBuilder {
        public typealias Body = Never
        let content: Content

        public init(@SwiftUI.ViewBuilder content: () -> Content) {
            self.content = content()
        }

        public var body: Never {
            fatalError("body of SwiftUIViewRepresentable should not be called")
        }

        func buildViewNode(in context: BuildContext) -> ViewNode {
            #if canImport(AppKit) && os(macOS)
                return AppKitViewRepresentableView(representable: AppKitWrapper(content: content))
                    .buildViewNode(in: context)
            #elseif canImport(UIKit) && (os(iOS) || os(tvOS) || os(visionOS))
                return UIKitViewRepresentableView(representable: UIKitWrapper(content: content))
                    .buildViewNode(in: context)
            #else
                fatalError("Platform not supported for SwiftUIViewRepresentable")
            #endif
        }
    }

    #if canImport(AppKit) && os(macOS)
        import AppKit
        private struct AppKitWrapper<Content: SwiftUI.View>: AppKitViewRepresentable {
            let content: Content
            func makeNSView(context _: Context) -> NSHostingView<Content> {
                let view = NSHostingView(rootView: content)
                view.isFlipped = true
                view.wantsLayer = true
                view.layer?.isOpaque = false
                return view
            }
            func updateNSView(_ nsView: NSHostingView<Content>, context _: Context) {
                nsView.rootView = content
            }
            func sizeThatFits(_: ProposedViewSize, nsView: NSHostingView<Content>, context _: Context) -> Size {
                let size = nsView.fittingSize
                return Size(width: Float(size.width), height: Float(size.height))
            }
        }
    #endif

    #if canImport(UIKit) && (os(iOS) || os(tvOS) || os(visionOS))
        import UIKit
        private struct UIKitWrapper<Content: SwiftUI.View>: UIKitViewRepresentable {
            let content: Content
            func makeUIView(context _: Context) -> _UIHostingView<Content> {
                let view = _UIHostingView(rootView: content)
                view.backgroundColor = .clear
                return view
            }
            func updateUIView(_ uiView: _UIHostingView<Content>, in _: Context) {
                uiView.rootView = content
            }
        }

        // Minimal UIKit hosting view wrapper
        final class _UIHostingView<Content: SwiftUI.View>: UIKit.UIView {
            private let hostingController: SwiftUI.UIHostingController<Content>
            var rootView: Content {
                get { hostingController.rootView }
                set { hostingController.rootView = newValue }
            }
            init(rootView: Content) {
                self.hostingController = SwiftUI.UIHostingController(rootView: rootView)
                super.init(frame: .zero)
                self.addSubview(hostingController.view)
                hostingController.view.backgroundColor = .clear
            }
            @available(*, unavailable)
            required init?(coder _: NSCoder) { fatalError("Unreachable code") }
            override func layoutSubviews() {
                super.layoutSubviews()
                hostingController.view.frame = self.bounds
            }
            override func sizeThatFits(_ size: CGSize) -> CGSize {
                return hostingController.view.sizeThatFits(size)
            }
        }
    #endif

#endif
