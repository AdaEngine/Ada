#if os(macOS) || os(Windows) || os(Linux)
import AdaEngine
import Foundation

@MainActor
enum EditorCLIInstallationPresentation {
    static func install() {
        do {
            let directory = try EditorCLIInstallation.install()
            show(title: L10n.text("Command Installed"),
                 message: L10n.text("The adastudio command is installed in \(directory.path). Restart your terminal, then run adastudio . in your project folder."))
        } catch {
            let message: String
            if let installationError = error as? EditorCLIInstallation.InstallationError {
                switch installationError {
                case .launcherUnavailable:
                    message = L10n.text("The command-line launcher is missing. Install the complete standalone version of Ada Studio first.")
                case let .existingCommand(path):
                    message = L10n.text("A different command already exists at \(path). Move or rename it, then try again.")
                case let .damagedProfile(path):
                    message = L10n.text("The Ada Studio PATH entry in \(path) is incomplete. Remove that entry, then try again.")
                case let .registry(code):
                    message = L10n.text("Could not update your PATH (Windows error \(code)).")
                }
            } else {
                message = L10n.text("Could not install the adastudio command: \(error.localizedDescription)")
            }
            show(title: L10n.text("Command Installation Failed"), message: message)
        }
    }

    private static func show(title: String, message: String) {
        #if os(Linux)
        Task {
            _ = await EditorProcessRunner().run(EditorProcessCommand(
                executablePath: "/usr/bin/zenity", arguments: ["--info", "--title", title, "--text", message, "--no-markup"],
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser
            ))
        }
        #else
        Application.shared.showAlert(Alert(title: title, message: message, buttons: [.button(L10n.text("Done"))]))
        #endif
    }
}
#endif
