#if os(iOS)
@_spi(AdaEngine) import AdaEngine
import UIKit

struct MobileEditorAgentSettingsScreen: View {
    @Environment(\.theme) private var theme
    let modelStore: MobileEditorProviderModelStore
    let showModelPicker: () -> Void

    private var apiURL: String {
        get { modelStore.apiURL }
        nonmutating set { modelStore.apiURL = newValue }
    }
    private var apiKey: String {
        get { modelStore.apiKey }
        nonmutating set { modelStore.apiKey = newValue }
    }
    @State private var statusMessage = ""
    @State private var deviceCode: MobileCodexDeviceCode?
    @State private var isCodeCopied = false
    @State private var isAuthorizing = false
    @State private var authorizationBrowser = MobileCodexAuthorizationBrowser()
    @State private var authorizationTask: Task<Void, Never>?

    var body: some View {
        MobileEditorPageScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Connect an account, then choose a model for your projects.")
                    .font(MobileEditorFont.font(size: 13))
                    .foregroundColor(theme.editorColors.muted)

                modelSelection
                MobileEditorCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Codex authorization")
                            .font(MobileEditorFont.navigationFont(size: 20))
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
                                        .frame(height: 44)
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
                                .frame(minHeight: 44)
                                .disabled(isAuthorizing)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(17)
                }

                MobileEditorCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("OpenAI compatible API")
                            .font(MobileEditorFont.navigationFont(size: 20))
                            .foregroundColor(theme.editorColors.text)
                        settingsField("API URL", placeholder: MobileSloppyCredentials.defaultAPIURL, text: Binding(get: { apiURL }, set: { apiURL = $0 }))
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

                        MobileEditorPrimaryButton(title: "Choose API model") {
                            switchProvider(to: .api)
                            showModelPicker()
                        }
                        .disabled(apiKey.isEmpty)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(17)
                }

                MobileEditorCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Image generation").font(MobileEditorFont.navigationFont(size: 20))
                        Text("Generate and edit game textures with an OpenAI API key. Codex sign-in handles image understanding; image generation uses a separate API key.")
                            .font(MobileEditorFont.font(size: 12))
                            .foregroundColor(theme.editorColors.muted)
                        Button("Set image API key") {
                            MobileSloppyAPIKeyPrompt.present(currentValue: "") { key in
                                Task { @MainActor in
                                    do {
                                        try await EditorOpenAIImageCredentialStore().save(key)
                                        statusMessage = key.isEmpty ? "Image API key removed" : "Image API key saved securely"
                                    } catch { statusMessage = error.localizedDescription }
                                }
                            }
                        }
                        .accessibilityIdentifier("AdaEditor.Mobile.ImageAPIKey")
                    }
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
        .onAppear { reloadModels() }
        .onDisappear {
            modelStore.cancel()
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

    private var modelSelection: some View {
        Button {
            modelStore.beginSelection()
            showModelPicker()
        } label: {
            MobileEditorCard {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("MODEL · \(modelStore.selectedProviderTitle)")
                            .font(MobileEditorFont.font(size: 11))
                            .foregroundColor(theme.editorColors.muted)
                        Text(modelStore.selectedModelID.isEmpty ? "Choose a model" : modelStore.selectedTitle)
                            .font(MobileEditorFont.navigationFont(size: 20))
                            .foregroundColor(theme.editorColors.text)
                            .lineLimit(1)
                        Text(modelStore.isLoading ? "Loading available models…" : "Search and select in the model picker")
                            .font(MobileEditorFont.font(size: 12))
                            .foregroundColor(theme.editorColors.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\u{E5CC}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 24))
                        .foregroundColor(theme.editorColors.blue)
                }
                .padding(18)
            }
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.Mobile.ChooseModel")
    }

    private func switchProvider(to selected: MobileAgentProvider) {
        modelStore.switchProvider(to: selected)
    }

    private func saveProvider() {
        if !modelStore.save() { statusMessage = modelStore.errorMessage }
    }

    private func reloadModels() {
        modelStore.reload()
    }

    private func updateAPIKey() {
        MobileSloppyAPIKeyPrompt.present(currentValue: apiKey) { value in
            apiKey = value
            switchProvider(to: .api)
            saveProvider()
            reloadModels()
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
                        switchProvider(to: .codex)
                        saveProvider()
                        reloadModels()
                        statusMessage = "Codex connected. Open the model picker to choose a model."
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
            switchProvider(to: .api)
            saveProvider()
            reloadModels()
            statusMessage = "Codex disconnected."
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
#endif
