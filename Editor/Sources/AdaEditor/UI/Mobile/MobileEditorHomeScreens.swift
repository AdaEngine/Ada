#if os(iOS)
@_spi(AdaEngine) import AdaEngine
import UIKit

struct MobileEditorProjectsScreen: View {
    @Environment(\.theme) private var theme
    let projects: [MobileEditorProject]
    let create: () -> Void
    let open: (MobileEditorProject) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Your Worlds")
                        .font(MobileEditorFont.font(size: 34))
                        .foregroundColor(theme.editorColors.text)
                    Text("Choose a project or start a new game.")
                        .font(MobileEditorFont.font(size: 15))
                        .foregroundColor(theme.editorColors.muted)
                }

                Button(action: create) {
                    HStack(spacing: 14) {
                        Text("\u{E145}")
                            .font(AdaEditorMaterialSymbolFont.font(size: 24))
                            .foregroundColor(theme.editorColors.blue)
                            .frame(width: 48, height: 48)
                            .background(RoundedRectangleShape(cornerRadius: 14).fill(theme.editorColors.blue.opacity(0.15)))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Create Game")
                                .font(MobileEditorFont.font(size: 17))
                                .foregroundColor(theme.editorColors.text)
                            Text("Open your workspace")
                                .font(MobileEditorFont.font(size: 12))
                                .foregroundColor(theme.editorColors.muted)
                        }
                        Spacer()
                        Text("\u{E5CC}")
                            .font(AdaEditorMaterialSymbolFont.font(size: 16))
                            .foregroundColor(theme.editorColors.muted)
                    }
                    .padding(16)
                    .background(RoundedRectangleShape(cornerRadius: 18).fill(theme.editorColors.surface))
                    .overlay { RoundedRectangleShape(cornerRadius: 18).stroke(theme.editorColors.blue.opacity(0.4), lineWidth: 1) }
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.Mobile.CreateGame")

                Text("PROJECTS")
                    .font(MobileEditorFont.font(size: 11))
                    .foregroundColor(theme.editorColors.muted)
                    .padding(.top, 8)

                ForEach(projects) { project in
                    projectCard(project)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .background(theme.editorColors.background)
        .overlay(anchor: .bottom) {
            LinearGradient(
                colors: [.clear, .clear, theme.editorColors.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 76)
            .allowsHitTesting(false)
        }
        .safeAreaPadding(.top, -72)
    }

    private func projectCard(_ project: MobileEditorProject) -> some View {
        Button {
            open(project)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                if project.isExample {
                    MobileEditorForestImage(height: 160)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.title)
                            .font(MobileEditorFont.font(size: 18))
                            .foregroundColor(theme.editorColors.text)
                        Text(project.isExample ? "Example project · Open Build" : "Draft · Open Build")
                            .font(MobileEditorFont.font(size: 13))
                            .foregroundColor(theme.editorColors.muted)
                    }
                    Spacer()
                    Text("\u{E5CC}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 16))
                        .foregroundColor(theme.editorColors.blue)
                }
                .padding(.horizontal, project.isExample ? 0 : 17)
                .padding(.vertical, project.isExample ? 0 : 17)
            }
            .background(project.isExample ? theme.editorColors.background : theme.editorColors.surface)
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.Mobile.Project.\(project.id)")
    }
}

struct MobileEditorSettingsScreen: View {
    @Environment(\.theme) private var theme
    let agentStatus: String?
    let configureAgent: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                MobileEditorSectionHeading(eyebrow: "Ada Editor", title: "Settings")
                EditorCloudSettingsView()
                Button(action: configureAgent) {
                    settingsRow("Agent", detail: agentSettingsSummary)
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.Mobile.ConfigureAgent")
                settingsRow("Projects", detail: "Drafts currently live in app memory")
                settingsRow("Game Preview", detail: "A demo scene is available for now")
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .background(theme.editorColors.background)
    }

    private func settingsRow(_ title: String, detail: String) -> some View {
        MobileEditorCard {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(MobileEditorFont.font(size: 16))
                    .foregroundColor(theme.editorColors.text)
                Text(detail)
                    .font(MobileEditorFont.font(size: 13))
                    .foregroundColor(theme.editorColors.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(17)
        }
    }

    private var agentSettingsSummary: String {
        if let agentStatus, !agentStatus.isEmpty { return agentStatus }
        if MobileCodexCredentialStore.load() != nil { return "Codex connected" }
        if let credentials = MobileSloppyCredentialStore.load(), !credentials.apiKey.isEmpty {
            return credentials.model.isEmpty ? "OpenAI API key saved" : "\(credentials.model) configured"
        }
        return "Connect Codex or configure an OpenAI model"
    }
}

struct MobileEditorAgentSettingsScreen: View {
    @Environment(\.theme) private var theme
    @State private var apiURL: String
    @State private var apiKey: String
    @State private var modelID: String
    @State private var statusMessage = ""
    @State private var deviceCode: MobileCodexDeviceCode?
    @State private var isCodeCopied = false
    @State private var isAuthorizing = false
    @State private var authorizationBrowser = MobileCodexAuthorizationBrowser()
    @State private var authorizationTask: Task<Void, Never>?

    init() {
        let credentials = MobileSloppyCredentialStore.load() ?? MobileSloppyCredentials()
        _apiURL = State(initialValue: credentials.apiURL)
        _apiKey = State(initialValue: credentials.apiKey)
        _modelID = State(initialValue: credentials.model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                MobileEditorSectionHeading(eyebrow: "Providers", title: "OpenAI")
                MobileEditorCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Codex authorization")
                            .font(MobileEditorFont.font(size: 16))
                            .foregroundColor(theme.editorColors.text)
                        Text(MobileCodexCredentialStore.load() == nil ? "Sign in with your ChatGPT account to use Codex." : "Codex is connected on this device.")
                            .font(MobileEditorFont.font(size: 13))
                            .foregroundColor(theme.editorColors.muted)
                        if let deviceCode {
                            HStack(spacing: 10) {
                                Text(deviceCode.userCode)
                                    .font(MobileEditorFont.font(size: 32))
                                    .foregroundColor(theme.editorColors.blue)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityIdentifier("AdaEditor.Mobile.CodexDeviceCode")
                                Button {
                                    UIPasteboard.general.string = deviceCode.userCode
                                    isCodeCopied = true
                                } label: {
                                    Text(isCodeCopied ? "Copied" : "Copy")
                                        .font(MobileEditorFont.font(size: 13))
                                        .foregroundColor(theme.editorColors.blue)
                                        .padding(.horizontal, 12)
                                        .frame(height: 38)
                                        .background(RoundedRectangleShape(cornerRadius: 10).fill(theme.editorColors.blue.opacity(0.12)))
                                        .overlay {
                                            RoundedRectangleShape(cornerRadius: 10)
                                                .stroke(theme.editorColors.blue.opacity(0.35), lineWidth: 1)
                                                .allowsHitTesting(false)
                                        }
                                }
                                .buttonStyle(DefaultButtonStyle())
                                .accessibilityIdentifier("AdaEditor.Mobile.CopyCodexDeviceCode")
                            }
                            .padding(.vertical, 8)
                            Text("Paste this code in the sign-in window to finish signing in.")
                                .font(MobileEditorFont.font(size: 12))
                                .foregroundColor(theme.editorColors.muted)
                        }
                        MobileEditorPrimaryButton(
                            title: isAuthorizing ? "Waiting for Codex…" : (MobileCodexCredentialStore.load() == nil ? "Authorize Codex" : "Reconnect Codex"),
                            action: authorizeCodex
                        )
                        .disabled(isAuthorizing)
                        .accessibilityIdentifier("AdaEditor.Mobile.AuthorizeCodex")
                        if !statusMessage.isEmpty {
                            Text(statusMessage)
                                .font(MobileEditorFont.font(size: 12))
                                .foregroundColor(theme.editorColors.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("AdaEditor.Mobile.CodexAuthorizationStatus")
                        }
                        if MobileCodexCredentialStore.load() != nil {
                            Button("Disconnect Codex", action: disconnectCodex)
                                .foregroundColor(theme.editorColors.muted)
                                .disabled(isAuthorizing)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(17)
                }

                MobileEditorCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("OpenAI compatible API")
                            .font(MobileEditorFont.font(size: 16))
                            .foregroundColor(theme.editorColors.text)
                        settingsField("API URL", placeholder: MobileSloppyCredentials.defaultAPIURL, text: $apiURL)
                        Button(action: updateAPIKey) {
                            HStack {
                                Text(apiKey.isEmpty ? "Set API key" : "API key saved securely")
                                    .foregroundColor(theme.editorColors.text)
                                Spacer()
                                Text(apiKey.isEmpty ? "Add" : "Change")
                                    .foregroundColor(theme.editorColors.blue)
                            }
                            .font(MobileEditorFont.font(size: 14))
                            .padding(.horizontal, 12)
                            .frame(height: 44)
                            .background(RoundedRectangleShape(cornerRadius: 10).fill(theme.editorColors.background))
                            .overlay { RoundedRectangleShape(cornerRadius: 10).stroke(theme.editorColors.border, lineWidth: 1) }
                        }
                        settingsField("MODEL_ID", placeholder: "gpt-4.1", text: $modelID)
                        MobileEditorPrimaryButton(title: "Save provider") {
                            saveProvider()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(17)
                }

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(MobileEditorFont.font(size: 13))
                        .foregroundColor(theme.editorColors.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("AdaEditor.Mobile.AgentSettingsStatus")
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 32)
        }
        .background(theme.editorColors.background)
        .onDisappear {
            authorizationTask?.cancel()
            authorizationBrowser.dismiss()
        }
    }

    private func settingsField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(MobileEditorFont.font(size: 11))
                .foregroundColor(theme.editorColors.muted)
            TextField(placeholder, text: text)
                .textFieldStyle(PlainTextFieldStyle())
                .font(MobileEditorFont.font(size: 14))
                .foregroundColor(theme.editorColors.text)
                .padding(.horizontal, 14)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 48, maxHeight: 48)
                .background(RoundedRectangleShape(cornerRadius: 12).fill(theme.editorColors.background))
                .overlay {
                    RoundedRectangleShape(cornerRadius: 12)
                        .stroke(theme.editorColors.border.opacity(0.9), lineWidth: 1)
                        .allowsHitTesting(false)
                }
        }
    }

    private func saveProvider() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlText = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlText),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty,
              components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)) else {
            statusMessage = "Enter a valid HTTPS API URL. HTTP is available for localhost."
            return
        }
        guard !model.isEmpty else {
            statusMessage = "Enter MODEL_ID before saving provider settings."
            return
        }
        guard !key.isEmpty || MobileCodexCredentialStore.load() != nil else {
            statusMessage = "Enter API_KEY and MODEL_ID, or connect Codex above."
            return
        }
        do {
            try MobileSloppyCredentialStore.save(MobileSloppyCredentials(apiKey: key, model: model, apiURL: url.absoluteString))
            statusMessage = key.isEmpty
                ? "MODEL_ID saved. Ada Studio will use the connected Codex account."
                : "Provider settings saved securely on this device."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func updateAPIKey() {
        MobileSloppyAPIKeyPrompt.present(currentValue: apiKey) { value in
            apiKey = value
            if value.isEmpty {
                do {
                    let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                    let url = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    try MobileSloppyCredentialStore.save(MobileSloppyCredentials(apiKey: "", model: model, apiURL: url))
                    statusMessage = "API key cleared."
                } catch {
                    statusMessage = error.localizedDescription
                }
            } else {
                do {
                    let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                    let url = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    try MobileSloppyCredentialStore.save(MobileSloppyCredentials(apiKey: value, model: model, apiURL: url))
                    statusMessage = "API key saved securely on this device."
                } catch {
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func authorizeCodex() {
        guard !isAuthorizing else {
            return
        }
        isAuthorizing = true
        deviceCode = nil
        isCodeCopied = false
        statusMessage = "Starting Codex authorization…"
        authorizationTask = Task { @MainActor in
            defer {
                authorizationBrowser.dismiss()
                authorizationTask = nil
                isAuthorizing = false
            }
            do {
                let code = try await MobileCodexOAuth.start()
                try Task.checkCancellation()
                deviceCode = code
                guard authorizationBrowser.present(url: code.verificationURL, onDismiss: {
                    authorizationTask?.cancel()
                }) else {
                    statusMessage = "Could not show the sign-in window. Try again."
                    deviceCode = nil
                    return
                }
                UIPasteboard.general.string = code.userCode
                isCodeCopied = true
                statusMessage = "Code copied. Paste it in the sign-in window. Ada Studio will finish automatically."
                let interval = max(1, code.interval)
                for _ in 0..<max(1, code.expiresIn / interval) {
                    try await Task.sleep(for: .seconds(interval))
                    if try await MobileCodexOAuth.poll(code) {
                        statusMessage = "Codex connected."
                        deviceCode = nil
                        isCodeCopied = false
                        return
                    }
                }
                statusMessage = "Codex authorization expired. Try again."
                deviceCode = nil
                isCodeCopied = false
            } catch {
                statusMessage = Task.isCancelled
                    ? "Codex authorization cancelled."
                    : "Could not complete Codex sign-in: \(error.localizedDescription)"
                deviceCode = nil
                isCodeCopied = false
            }
        }
    }

    private func disconnectCodex() {
        authorizationTask?.cancel()
        authorizationBrowser.dismiss()
        do {
            try MobileCodexCredentialStore.delete()
            statusMessage = "Codex disconnected."
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
#endif
