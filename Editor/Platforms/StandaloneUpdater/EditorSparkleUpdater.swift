import AppKit
import Sparkle

/// Loaded explicitly by the SwiftPM editor from the standalone app's Frameworks directory.
@objc(AdaEditorSparkleUpdater)
@MainActor
final class EditorSparkleUpdater: NSObject, SPUUpdaterDelegate, @MainActor SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?
    private var pendingInstallation: (() -> Void)?
    private var version: String?
    private var startupError: String?

    @objc func startUpdater() {
        guard Bundle.main.object(forInfoDictionaryKey: "AdaEditorDistribution") as? String == "standalone" else { return }
        guard controller == nil else { return }
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            startupError = "This build does not have an update channel configured."
            publish(error: startupError)
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        do {
            try controller.updater.start()
        } catch {
            startupError = error.localizedDescription
            publish(error: startupError)
        }
    }

    @objc func checkForUpdates() {
        if let startupError {
            let alert = NSAlert()
            alert.messageText = "Unable to check for updates"
            alert.informativeText = startupError
            alert.runModal()
            return
        }
        if let installation = pendingInstallation {
            guard saveDocuments() else {
                publish(error: "Save your changes, then try Update again.")
                return
            }
            pendingInstallation = nil
            installation()
        } else {
            controller?.checkForUpdates(nil)
        }
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        version = update.displayVersionString
        publish()
    }

    func standardUserDriverWillFinishUpdateSession() {
        guard pendingInstallation == nil else { return }
        version = nil
        publish()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard !saveDocuments() else { return false }
        pendingInstallation = installHandler
        version = item.displayVersionString
        publish(error: "Some documents could not be saved. Save your changes, then try Update again.")
        return true
    }

    private func saveDocuments() -> Bool {
        // Fail closed if the host did not register its document-saving handler.
        let reply: NSMutableDictionary = ["canRestart": false]
        NotificationCenter.default.post(name: EditorUpdateBridge.prepareRestart, object: reply)
        return reply["canRestart"] as? Bool == true
    }

    private func publish(error: String? = nil) {
        var values: [String: String] = [:]
        values["version"] = version
        values["error"] = error
        NotificationCenter.default.post(name: EditorUpdateBridge.stateChanged, object: nil, userInfo: values)
    }
}
