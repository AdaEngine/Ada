@_spi(AdaEngine) import AdaEngine
import Foundation

#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

struct EditorSloppyInviteSettingsView: View {
    let catalog: EditorAgentCatalogViewModel
    var presentInvite: @MainActor (@escaping @MainActor (EditorSloppyInvitePrompt.Values) -> Void) -> Void = EditorSloppyInvitePrompt.present
    @Environment(\.theme) private var theme
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sloppy invite token")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(theme.editorColors.text)
            Text(catalog.registeredSloppy.map { "Registered as \($0.login) on \($0.serverURL.host ?? "Sloppy Core"). Session saved in Keychain." }
                ?? "Paste a Sloppy user invite (slp_inv_) to create an account on your Sloppy Core.")
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.muted)
            Button(catalog.isBusy ? "Registering…" : "Paste invite token") {
                presentInvite { values in
                    Task { @MainActor in
                        await catalog.registerSloppyInvite(
                            server: values.server,
                            invite: values.invite,
                            name: values.name,
                            login: values.login,
                            password: values.password
                        )
                        status = catalog.status
                    }
                }
            }
            .buttonStyle(EditorAgentCatalogActionButtonStyle(theme: theme, fontSize: 14, minimumHeight: 44))
            .disabled(catalog.isBusy)
            .accessibilityIdentifier("AdaEditor.Agents.SloppyInvite")
            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundColor(theme.editorColors.muted)
                    .accessibilityIdentifier("AdaEditor.Agents.SloppyInviteStatus")
            }
            #if os(macOS)
                Text("To use Sloppy in Agent Chat, connect its local ACP Server below.")
                    .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
            #else
                Text("This registers your Sloppy account. Choose Codex or an API model separately for the on-device agent.")
                    .font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("AdaEditor.Agents.SloppyInviteSettings")
        .onAppear { Task { await catalog.loadSloppyAccount() } }
    }
}

@MainActor
enum EditorSloppyInvitePrompt {
    struct Values: Sendable {
        let server: String
        let invite: String
        let name: String
        let login: String
        let password: String
    }

    static func present(completion: @escaping @MainActor (Values) -> Void) {
        #if os(macOS)
            let alert = NSAlert()
            alert.messageText = "Create a Sloppy account"
            alert.informativeText = "Use the server address and one-time user invite supplied by your Sloppy administrator."
            alert.addButton(withTitle: "Create account")
            alert.addButton(withTitle: "Cancel")
            let server = NSTextField(string: "")
            server.placeholderString = "https://your-sloppy-core.example"
            let invite = NSSecureTextField(string: "")
            invite.placeholderString = "Invite token (slp_inv_)"
            let name = NSTextField(string: "")
            name.placeholderString = "Name"
            let login = NSTextField(string: "")
            login.placeholderString = "Login"
            let password = NSSecureTextField(string: "")
            password.placeholderString = "Password"
            let stack = NSStackView(views: [server, invite, name, login, password])
            stack.orientation = .vertical
            stack.spacing = 8
            stack.frame = NSRect(x: 0, y: 0, width: 360, height: 180)
            for field in [server, invite, name, login, password] {
                field.translatesAutoresizingMaskIntoConstraints = false
                field.widthAnchor.constraint(equalToConstant: 360).isActive = true
                field.heightAnchor.constraint(equalToConstant: 28).isActive = true
            }
            alert.accessoryView = stack
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
            completion(Values(server: server.stringValue, invite: invite.stringValue, name: name.stringValue, login: login.stringValue, password: password.stringValue))
        #elseif os(iOS)
            let alert = UIAlertController(
                title: "Create a Sloppy account",
                message: "Paste your one-time user invite and enter your Sloppy Core address and new account details.",
                preferredStyle: .alert
            )
            for (index, placeholder) in ["https://your-sloppy-core.example", "Invite token (slp_inv_)", "Name", "Login", "Password"].enumerated() {
                alert.addTextField { field in
                    field.placeholder = placeholder
                    field.accessibilityIdentifier = "AdaEditor.Agents.SloppyInvite.Field.\(index)"
                    field.autocapitalizationType = .none
                    field.autocorrectionType = .no
                    field.isSecureTextEntry = index == 1 || index == 4
                    if index == 0 { field.keyboardType = .URL }
                    if index == 3 { field.textContentType = .username }
                    if index == 4 { field.textContentType = .newPassword }
                }
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Create account", style: .default) { _ in
                guard let fields = alert.textFields, fields.count == 5 else {
                    return
                }
                completion(Values(
                    server: fields[0].text ?? "",
                    invite: fields[1].text ?? "",
                    name: fields[2].text ?? "",
                    login: fields[3].text ?? "",
                    password: fields[4].text ?? ""
                ))
            })
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
                  let window = scene.keyWindow,
                  var presenter = window.rootViewController else { return }
            while let presented = presenter.presentedViewController { presenter = presented }
            presenter.present(alert, animated: true)
        #endif
    }
}
