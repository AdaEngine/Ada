#if os(iOS)
@_spi(AdaEngine) import AdaEngine

struct MobileEditorModelPickerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var query = ""
    let modelStore: MobileEditorProviderModelStore

    private var visibleModels: [EditorProviderModel] {
        EditorProviderModelCatalog.matching(modelStore.models, query: query)
    }

    var body: some View {
        NavigationStack {
            MobileEditorPageScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    providerControl
                    searchField
                    HStack {
                        Text(modelStore.isLoading ? "Loading models…" : "\(query.isEmpty ? "Available models" : "Search results") · \(visibleModels.count)")
                            .font(MobileEditorFont.font(size: 12))
                            .foregroundColor(theme.editorColors.muted)
                        Spacer()
                        Button("Refresh") { modelStore.reload() }
                            .font(MobileEditorFont.font(size: 13))
                            .foregroundColor(theme.editorColors.text)
                            .frame(minHeight: 44)
                            .disabled(modelStore.isLoading)
                            .accessibilityIdentifier("AdaEditor.Mobile.RefreshModels")
                    }
                    if !modelStore.errorMessage.isEmpty {
                        messageCard(title: "Could not load models", detail: modelStore.errorMessage)
                            .accessibilityIdentifier("AdaEditor.Mobile.ModelCatalogError")
                    }
                    if modelStore.isLoading && modelStore.models.isEmpty {
                        messageCard(title: "Loading your models", detail: "Fetching the catalog from \(modelStore.providerTitle)…")
                    } else if visibleModels.isEmpty {
                        if modelStore.errorMessage.isEmpty {
                            messageCard(
                                title: query.isEmpty ? "No models available" : "No matching models",
                                detail: query.isEmpty ? "Refresh the catalog or choose another provider." : "Search by model name or ID."
                            )
                            if !query.isEmpty {
                                Button("Clear search") { query = "" }
                                    .foregroundColor(theme.editorColors.text)
                                    .frame(minHeight: 44)
                                    .accessibilityIdentifier("AdaEditor.Mobile.ClearModelSearch")
                            }
                        }
                    } else {
                        VStack(spacing: 10) {
                            ForEach(visibleModels) { model in
                                modelRow(model)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("AdaEditor.Mobile.ModelList")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: 640, alignment: .topLeading)
                .frame(maxWidth: .infinity)
            }
            .background(theme.editorColors.background)
            .navigationTitle("Choose model")
            .navigationTitleFont(MobileEditorFont.navigationFont(size: 22))
            .navigationTitlePosition(.center)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarColor(theme.editorColors.background)
            .navigationBarTrailingItems {
                Button { dismiss() } label: {
                    Text("\u{E5CD}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 24))
                        .foregroundColor(theme.editorColors.text)
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("AdaEditor.Mobile.ModelPicker.Close")
            }
        }
        .background(theme.editorColors.background.ignoresSafeArea())
        .onAppear { modelStore.reload() }
        .onDisappear { modelStore.cancel() }
        .accessibilityIdentifier("AdaEditor.Mobile.ModelPicker")
    }

    private var providerControl: some View {
        HStack(spacing: 8) {
            providerButton(.codex, title: "Codex", enabled: modelStore.isCodexConnected)
            providerButton(.api, title: "API key", enabled: !modelStore.apiKey.isEmpty)
        }
        .padding(5)
        .background(RoundedRectangleShape(cornerRadius: 15).fill(theme.editorColors.surface))
    }

    private func providerButton(_ provider: MobileAgentProvider, title: String, enabled: Bool) -> some View {
        let selected = provider == modelStore.provider
        return Button {
            modelStore.switchProvider(to: provider)
            query = ""
            modelStore.reload()
        } label: {
            HStack(spacing: 8) {
                if selected {
                    Text("\u{E5CA}").font(AdaEditorMaterialSymbolFont.font(size: 18))
                }
                Text(title).font(MobileEditorFont.font(size: 14))
            }
            .foregroundColor(selected ? .white : theme.editorColors.text.opacity(enabled ? 1 : 0.45))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangleShape(cornerRadius: 11).fill(selected ? theme.editorColors.blue.opacity(0.85) : .clear))
        }
        .buttonStyle(DefaultButtonStyle())
        .disabled(!enabled)
        .accessibilityIdentifier("AdaEditor.Mobile.ModelProvider.\(provider.rawValue)")
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Text("\u{E8B6}")
                .font(AdaEditorMaterialSymbolFont.font(size: 22))
                .foregroundColor(theme.editorColors.muted)
            TextField("Search models by name or ID", text: $query)
                .textFieldStyle(PlainTextFieldStyle())
                .font(MobileEditorFont.font(size: 13))
                .foregroundColor(theme.editorColors.text)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("AdaEditor.Mobile.ModelSearch")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Text("\u{E5CD}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 20))
                        .foregroundColor(theme.editorColors.muted)
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("AdaEditor.Mobile.ModelSearch.Clear")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(RoundedRectangleShape(cornerRadius: 13).fill(theme.editorColors.surface))
        .overlay {
            RoundedRectangleShape(cornerRadius: 13)
                .stroke(theme.editorColors.border, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func modelRow(_ model: EditorProviderModel) -> some View {
        let selected = model.id == modelStore.modelID
        return Button {
            if modelStore.select(model) { dismiss() }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.title)
                        .font(MobileEditorFont.navigationFont(size: 19))
                        .foregroundColor(theme.editorColors.text)
                    Text(model.id)
                        .font(MobileEditorFont.font(size: 12))
                        .foregroundColor(theme.editorColors.muted)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Text("\u{E86C}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 24))
                        .foregroundColor(theme.editorColors.blue)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(RoundedRectangleShape(cornerRadius: 16).fill(theme.editorColors.surface))
            .overlay {
                RoundedRectangleShape(cornerRadius: 16)
                    .stroke(selected ? theme.editorColors.blue : theme.editorColors.border.opacity(0.7), lineWidth: selected ? 2 : 1)
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(DefaultButtonStyle())
        .disabled(modelStore.isLoading)
        .accessibilityIdentifier("AdaEditor.Mobile.Model.\(model.id)")
    }

    private func messageCard(title: String, detail: String) -> some View {
        MobileEditorCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(MobileEditorFont.navigationFont(size: 19))
                    .foregroundColor(theme.editorColors.text)
                Text(detail)
                    .font(MobileEditorFont.font(size: 13))
                    .foregroundColor(theme.editorColors.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
    }
}
#endif
