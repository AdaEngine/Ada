import Foundation
import Observation

#if os(macOS)
    import AppKit
#endif

@Observable
@MainActor
final class EditorUpdateCenter: NSObject {
    static let shared = EditorUpdateCenter()

    private(set) var availableVersion: String?
    private(set) var errorMessage: String?
    @ObservationIgnored private var backend: NSObject?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var workbenches: [WeakWorkbench] = []

    private struct WeakWorkbench {
        weak var value: EditorWorkbenchViewModel?
    }

    func register(_ workbench: EditorWorkbenchViewModel) {
        workbenches.removeAll { $0.value == nil }
        guard !workbenches.contains(where: { $0.value === workbench }) else {
            return
        }
        workbenches.append(WeakWorkbench(value: workbench))
    }

    func saveBeforeRestart() -> Bool {
        workbenches.removeAll { $0.value == nil }
        var succeeded = true
        for entry in workbenches where entry.value?.saveAllDocuments() == false {
            succeeded = false
        }
        if !succeeded {
            errorMessage = "Some documents could not be saved. Save your changes, then try Update again."
        }
        return succeeded
    }

    func start() {
        #if os(macOS)
            guard EditorDistribution.current == .standalone, !started else {
                return
            }
            started = true
            NotificationCenter.default.addObserver(self, selector: #selector(receiveState(_:)), name: EditorUpdateBridge.stateChanged, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(prepareRestart(_:)), name: EditorUpdateBridge.prepareRestart, object: nil)
            guard
                let frameworks = Bundle.main.privateFrameworksURL,
                let bundle = Bundle(url: frameworks.appendingPathComponent(EditorUpdateBridge.frameworkName))
            else {
                errorMessage = "Updates are unavailable in this development build."
                return
            }
            do {
                try bundle.loadAndReturnError()
                guard let backendType = bundle.principalClass as? NSObject.Type else {
                    errorMessage = "The updater could not be loaded."
                    return
                }
                let instance = backendType.init()
                backend = instance
                instance.perform(NSSelectorFromString("startUpdater"))
            } catch {
                errorMessage = "The updater could not be loaded: \(error.localizedDescription)"
            }
        #endif
    }

    func checkForUpdates() {
        #if os(macOS)
            guard EditorDistribution.current == .standalone else {
                return
            }
            start()
            guard saveBeforeRestart() else {
                showError()
                return
            }
            if let backend {
                backend.perform(NSSelectorFromString("checkForUpdates"))
            } else {
                showError()
            }
        #endif
    }

    #if os(macOS)
        @objc private func receiveState(_ notification: Notification) {
            availableVersion = notification.userInfo?["version"] as? String
            errorMessage = notification.userInfo?["error"] as? String
        }

        @objc private func prepareRestart(_ notification: Notification) {
            guard let reply = notification.object as? NSMutableDictionary else {
                return
            }
            reply["canRestart"] = saveBeforeRestart()
        }

        private func showError() {
            let alert = NSAlert()
            alert.messageText = "Unable to update"
            alert.informativeText = errorMessage ?? "Please try again later."
            alert.runModal()
        }
    #endif
}
