#if os(iOS)
import Foundation
import SafariServices
import UIKit

/// Presents the device-code verification page while the app polls for authorization.
@MainActor
final class MobileCodexAuthorizationBrowser: NSObject, @MainActor SFSafariViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    private var controller: SFSafariViewController?
    private var onDismiss: (@MainActor () -> Void)?

    func present(url: URL, onDismiss: @escaping @MainActor () -> Void) -> Bool {
        guard controller == nil, url.scheme == "https", url.host != nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive && $0.keyWindow != nil }),
              var presenter = scene.keyWindow?.rootViewController else { return false }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        guard presenter.viewIfLoaded?.window != nil,
              !presenter.isBeingPresented, !presenter.isBeingDismissed else { return false }

        let controller = SFSafariViewController(url: url)
        controller.delegate = self
        controller.dismissButtonStyle = .cancel
        controller.modalPresentationStyle = .pageSheet
        controller.presentationController?.delegate = self
        self.controller = controller
        self.onDismiss = onDismiss
        presenter.present(controller, animated: true)
        return true
    }

    /// Programmatic completion does not invoke the user's cancellation callback.
    func dismiss() {
        onDismiss = nil
        let controller = self.controller
        self.controller = nil
        controller?.dismiss(animated: true)
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        guard self.controller === controller else {
            return
        }
        let onDismiss = self.onDismiss
        dismiss()
        onDismiss?()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === controller else {
            return
        }
        let onDismiss = self.onDismiss
        self.onDismiss = nil
        controller = nil
        onDismiss?()
    }
}
#endif
