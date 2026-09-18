import AdaEngine
import Foundation

#if canImport(AppKit)
    import AppKit
#endif
#if canImport(SwiftUI)
    import SwiftUI
#endif
#if canImport(UIKit)
    import UIKit
#endif

@MainActor
enum EditorDocumentationWindowController {
    #if os(macOS)
        // Retain the singleton native reader independently of engine-rendered windows.
        private static let coordinator = WindowCoordinator()

        static func makeWindow(viewModel: EditorDocumentationViewModel) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Ada Documentation"
            window.minSize = NSSize(width: 760, height: 520)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: EditorDocumentationView(viewModel: viewModel))
            window.setContentSize(NSSize(width: 1060, height: 760))
            window.center()
            return window
        }

        @discardableResult
        static func open() -> Bool {
            if let window = coordinator.window {
                window.makeKeyAndOrderFront(nil)
                return true
            }
            let model = EditorDocumentationViewModel()
            let window = makeWindow(viewModel: model)
            coordinator.model = model
            coordinator.window = window
            window.delegate = coordinator
            window.makeKeyAndOrderFront(nil)
            return true
        }

        static func handleMenuCommand(_ command: EditorMenuCommand, keyWindow: NSWindow? = NSApp.keyWindow) -> Bool? {
            guard let window = coordinator.window, window === keyWindow else {
                return nil
            }
            switch command {
            case .closeEditor:
                window.close()
            case .navigateBack:
                coordinator.model?.goBack()
            case .navigateForward:
                coordinator.model?.goForward()
            case .cut,
                .copy,
                .paste,
                .selectAll,
                .undo,
                .redo:
                let selectors: [EditorMenuCommand: String] = [
                    .cut: "cut:", .copy: "copy:", .paste: "paste:",
                    .selectAll: "selectAll:", .undo: "undo:", .redo: "redo:",
                ]
                guard let selector = selectors[command] else {
                    return false
                }
                return NSApp.sendAction(Selector(selector), to: nil, from: nil)
            case .minimizeWindow,
                .zoomWindow,
                .bringAllToFront,
                .enterFullScreen,
                .showSourceRepository:
                return nil
            default:
                return false
            }
            return true
        }

        private final class WindowCoordinator: NSObject, NSWindowDelegate {
            var window: NSWindow?
            var model: EditorDocumentationViewModel?

            func windowWillClose(_: Notification) {
                window = nil
                model = nil
            }
        }
    #elseif os(iOS)
        private static weak var presentedController: UIViewController?

        @discardableResult
        static func open() -> Bool {
            if presentedController != nil {
                return true
            }
            var presenter = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)?
                .rootViewController
            while let presented = presenter?.presentedViewController { presenter = presented }
            guard let presenter else {
                return false
            }
            let controller = UIHostingController(
                rootView: EditorDocumentationView(
                    viewModel: EditorDocumentationViewModel(),
                    onClose: { presentedController?.dismiss(animated: true) }
                )
            )
            controller.modalPresentationStyle = .pageSheet
            presentedController = controller
            presenter.present(controller, animated: true)
            return true
        }
    #else
        @discardableResult
        static func open() -> Bool { false }
    #endif

    static func copy(_ text: String) {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
            UIPasteboard.general.string = text
        #endif
    }
}

struct EditorDocumentationButton: AdaEngine.View {
    var body: some AdaEngine.View {
        AdaEngine.Button("Documentation") {
            EditorMenuCommandRouter.shared.perform(.showDocumentation)
        }
        .font(.system(size: 12))
        .accessibilityIdentifier("AdaEditor.Documentation.Open")
    }
}
