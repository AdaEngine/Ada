@_spi(AdaEngine) import AdaEngine
import Foundation
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

@MainActor
struct EditorCloudSettingsView: View {
    private var account: EditorCloudAccount { .shared }
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(account.accountID == nil ? "Sign in to Ada Cloud" : "Ada Cloud account")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(theme.editorColors.text)
                Text(
                    account.accountID == nil
                        ? "Connect Ada Studio to your Ada Cloud account. Continue securely in your browser."
                        : (!account.cloudServicesAvailable ? "Cloud Services will open soon." : account.pro ? "Pro · Web publishing enabled" : "Free · Editor settings sync")
                )
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.muted)
                .lineLimit(3)
            }
            if account.accountID == nil {
                actionButton(account.busy ? "Waiting for browser…" : "Sign in with browser", primary: true, id: "SignIn") {
                    account.perform { try await account.signInOnWebsite() }
                }
            } else {
                if let accountID = account.accountID {
                    Text("Signed in · \(accountID)")
                        .font(.system(size: 12))
                        .foregroundColor(theme.editorColors.text)
                        .lineLimit(2)
                        .accessibilityIdentifier("AdaEditor.Cloud.AccountIdentity")
                }
                if let date = account.expiresAt {
                    Text("Paid access until \(date.formatted())").font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
                }
                HStack(spacing: 10) {
                    if account.cloudServicesAvailable {
                        actionButton("Sync now", id: "Sync") {
                            account.perform {
                                try await account.sync()
                                try await account.refreshPlan()
                                account.status = account.cloudServicesAvailable ? "Settings synced." : "Cloud Services will open soon."
                            }
                        }
                    }
                    actionButton("Manage account", id: "Manage") { EditorCloudFilePicker.open(account.server + "/cloud") }
                }
                HStack(spacing: 10) {
                    if account.billingAvailable {
                        actionButton("Subscribe to Pro", id: "Subscribe") { account.perform { try await account.buyPro() } }
                    }
                    actionButton("Restore purchases", id: "Restore") { account.perform { try await account.restorePurchases() } }
                }
                if account.cloudServicesAvailable {
                    Text("One active build · ZIP up to 300 MB · Secret links last 48 hours")
                        .font(.system(size: 11)).foregroundColor(theme.editorColors.muted).lineLimit(2)
                    actionButton("Choose ZIP and publish", id: "Publish") {
                        account.perform {
                            guard let url = try await EditorCloudFilePicker.shared.pick() else {
                                return
                            }
                            try await account.publish(zip: url)
                        }
                    }
                }
                if let url = account.publicationURL {
                    Text(url).font(.system(size: 11)).foregroundColor(theme.editorColors.muted).lineLimit(2)
                    HStack(spacing: 10) {
                        actionButton("Open game", id: "OpenGame") { EditorCloudFilePicker.open(url) }
                        actionButton("Copy link", id: "CopyLink") { EditorCloudFilePicker.copy(url) }
                    }
                }
                actionButton("Sign out on all devices", id: "SignOut") { account.perform { try await account.signOut() } }
            }
            if !account.status.isEmpty {
                Text(account.status).font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                    .lineLimit(4).accessibilityIdentifier("AdaEditor.Cloud.Status")
            }
        }
#if os(iOS)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, account.accountID == nil ? 8 : 16)
#else
        .padding(16)
#endif
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
#if os(iOS)
        .background(RoundedRectangleShape(cornerRadius: 18).fill(theme.editorColors.surface))
        .overlay { RoundedRectangleShape(cornerRadius: 18).stroke(theme.editorColors.border.opacity(0.7), lineWidth: 1) }
#else
        .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.surface))
        .overlay { RoundedRectangleShape(cornerRadius: 8).stroke(theme.editorColors.border, lineWidth: 1) }
#endif
        .accessibilityIdentifier("AdaEditor.Cloud.AccountCard")
        .onAppear { Self.installSync() }
    }

    private func actionButton(_ title: String, primary: Bool = false, id: String, action: @escaping () -> Void) -> some View {
        Button {
            if !account.busy {
                action()
            }
        } label: {
#if os(iOS)
            HStack {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundColor(primary ? .white : theme.editorColors.text)
                Spacer(minLength: 0)
                Text("\u{E5CC}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 20))
                    .foregroundColor(primary ? .white : theme.editorColors.text)
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangleShape(cornerRadius: 15).fill(primary ? theme.editorColors.blue : theme.editorColors.background))
            .overlay { RoundedRectangleShape(cornerRadius: 15).stroke(primary ? theme.editorColors.blue : theme.editorColors.border, lineWidth: 1) }
            .opacity(account.busy ? 0.6 : 1)
#else
            Text(title).font(.system(size: 12))
                .foregroundColor(primary ? .white : theme.editorColors.text)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(RoundedRectangleShape(cornerRadius: 6).fill(primary ? theme.editorColors.blue : theme.editorColors.background))
                .overlay { RoundedRectangleShape(cornerRadius: 6).stroke(primary ? theme.editorColors.blue : theme.editorColors.border, lineWidth: 1) }
                .opacity(account.busy ? 0.6 : 1)
#endif
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.Cloud.\(id)")
    }

    static func installSync() {
        EditorCloudAccount.shared.applySettings = { values in
            EditorCloudPreferences.shared.apply(values)
            let appearance = EditorAppearanceSettings.shared
            appearance.agentActivityGlowEnabled = values["appearance.agentActivityGlowEnabled"].bool ?? true
            appearance.agentGlowRadius = values["appearance.agentGlowRadius"] == .null ? EditorAppearanceSettings.defaultRadius : values["appearance.agentGlowRadius"].seconds
            appearance.agentGlowOpacity = values["appearance.agentGlowOpacity"] == .null ? EditorAppearanceSettings.defaultOpacity : values["appearance.agentGlowOpacity"].seconds
            if let hex = values["appearance.agentGlowAccent"].string, let color = EditorUIColorField.color(hex) {
                appearance.setAccentColor(color)
            } else {
                appearance.useThemeAccent()
            }
        }
        EditorCloudAccount.shared.start()
    }
}

@MainActor
private final class EditorCloudFilePicker: NSObject {
    static let shared = EditorCloudFilePicker()
    #if os(iOS)
        private var continuation: CheckedContinuation<URL?, Error>?
    #endif
    func pick() async throws -> URL? {
        #if os(macOS)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.zip]
            return await panel.begin() == .OK ? panel.url : nil
        #elseif os(iOS)
            guard
                let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow),
                var controller = window.rootViewController
            else {
                return nil
            }
            while let next = controller.presentedViewController { controller = next }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.zip], asCopy: false)
                picker.delegate = self
                controller.present(picker, animated: true)
            }
        #else
            return nil
        #endif
    }
    static func open(_ text: String) {
        guard let url = URL(string: text), url.scheme == "https" else {
            return
        }
        #if os(macOS)
            NSWorkspace.shared.open(url)
        #elseif os(iOS)
            UIApplication.shared.open(url)
        #endif
    }
    static func copy(_ text: String) {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
            UIPasteboard.general.string = text
        #endif
    }
}
#if os(iOS)
    extension EditorCloudFilePicker: UIDocumentPickerDelegate {
        func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            continuation?.resume(returning: urls.first)
            continuation = nil
        }
        func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
            continuation?.resume(returning: nil)
            continuation = nil
        }
    }
#endif
