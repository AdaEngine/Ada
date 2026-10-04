#if canImport(UIKit) && canImport(SwiftUI)
    import AdaUI
    import Foundation
    import SwiftUI

    /// Places an existing AdaUI panel inside a SwiftUI window. Content and local AdaUI
    /// state survive SwiftUI updates; the native host owns rendering and input only.
    @MainActor
    public struct AdaUIHost<Content: AdaUI.View>: SwiftUI.UIViewRepresentable {
        private let content: Content
        private let assetBundle: Bundle?
        private let onError: (@MainActor (Error) -> Void)?

        public init(
            assetBundle: Bundle? = nil,
            onError: (@MainActor (Error) -> Void)? = nil,
            @AdaUI.ViewBuilder content: () -> Content
        ) {
            self.content = content()
            self.assetBundle = assetBundle
            self.onError = onError
        }

        public func makeUIView(context: Context) -> AdaUIHostingView<Content> {
            let view = AdaUIHostingView(content: content, assetBundle: assetBundle)
            view.onError = onError
            return view
        }

        public func updateUIView(_ uiView: AdaUIHostingView<Content>, context: Context) {
            uiView.onError = onError
            uiView.updateContent(content, colorScheme: context.environment.colorScheme == .dark ? .dark : .light)
        }

        public static func dismantleUIView(_ uiView: AdaUIHostingView<Content>, coordinator _: ()) {
            uiView.stop()
        }
    }
#endif
