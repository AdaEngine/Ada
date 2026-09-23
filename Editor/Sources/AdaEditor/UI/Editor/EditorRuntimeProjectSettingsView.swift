@_spi(AdaEngine) import AdaEngine

struct EditorRuntimeProjectSettingsView: View {
    let projectName: String
    let viewModel: EditorSettingsWindowViewModel

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            entrySettings
            profileSettings
            pluginSettings
            if viewModel.isRuntimePluginEnabled(.physics2D) {
                physicsSettings
            }
            windowSettings
        }
    }

    private var entrySettings: some View {
        settingsGroup(EditorSettingsPage.runtimeEntry) {
            settingsField("Game", detail: "AdaScript module name.", text: viewModel.runtimeTextBinding(\.moduleName))
            settingsField("game.main", detail: "Optional root AdaUI view identifier.", text: viewModel.runtimeTextBinding(\.view))
                .accessibilityIdentifier("AdaEditor.Settings.RuntimeEntry.View")
            settingsField(
                "game.bootstrap",
                detail: "Optional @system id using the startup scheduler.",
                text: viewModel.runtimeTextBinding(\.startupSystem)
            )
        }
    }

    private var profileSettings: some View {
        settingsGroup("RUNTIME PROFILE") {
            HStack(spacing: 8) {
                ForEach(AdaProjectRuntimePluginPreset.allCases, id: \.self) { preset in
                    selectionButton(
                        preset.displayName,
                        selected: viewModel.runtimeSettings.plugins.preset == preset
                    ) {
                        viewModel.selectRuntimePreset(preset)
                    }
                }
            }
        }
    }

    private var pluginSettings: some View {
        settingsGroup("FEATURE PLUGINS") {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(EditorAdaScriptRuntimePluginCatalog.settingsSections) { section in
                    pluginSection(section)
                }
            }
        }
    }

    private func pluginSection(_ section: EditorAdaScriptRuntimePluginSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title.uppercased())
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("AdaEditor.Settings.PluginSection.\(section.id)")
            if !section.plugins.isEmpty {
                pluginRows(section.plugins)
            }
            ForEach(section.sections) { child in
                VStack(alignment: .leading, spacing: 4) {
                    Text(child.title)
                        .font(.system(size: 12))
                        .foregroundColor(theme.editorColors.text)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("AdaEditor.Settings.PluginSection.\(section.id).\(child.id)")
                    pluginRows(child.plugins)
                }
                .padding(.leading, 16)
            }
        }
    }

    private func pluginRows(_ pluginIDs: [AdaProjectRuntimePluginID]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(pluginIDs, id: \.self) { pluginID in
                if let descriptor = EditorAdaScriptRuntimePluginCatalog.descriptorByID[pluginID] {
                    pluginRow(descriptor)
                }
            }
        }
    }

    private func pluginRow(_ descriptor: EditorAdaScriptRuntimePluginDescriptor) -> some View {
        let isEnabled = viewModel.isRuntimePluginEnabled(descriptor.id)
        return settingsRow(title: descriptor.displayName, detail: descriptor.id.rawValue) {
            selectionButton(isEnabled ? "Enabled" : "Disabled", selected: isEnabled) {
                viewModel.toggleRuntimePlugin(descriptor.id)
            }
        }
    }

    private var physicsSettings: some View {
        settingsGroup("PHYSICS 2D") {
            HStack(spacing: 10) {
                settingsField("0", detail: "Gravity X", text: viewModel.runtimeTextBinding(\.gravityX))
                settingsField("-9.81", detail: "Gravity Y", text: viewModel.runtimeTextBinding(\.gravityY))
            }
        }
    }

    private var windowSettings: some View {
        settingsGroup("DISPLAY") {
            settingsField(
                projectName,
                detail: "Window title. Empty uses the project name.",
                text: viewModel.runtimeTextBinding(\.windowTitle)
            )
            HStack(spacing: 10) {
                settingsField("1024", detail: "Width", text: viewModel.runtimeTextBinding(\.windowWidth))
                settingsField("700", detail: "Height", text: viewModel.runtimeTextBinding(\.windowHeight))
            }
            selectionButton(
                viewModel.runtimeDraft.windowIsResizable ? "Resizable" : "Fixed Size",
                selected: viewModel.runtimeDraft.windowIsResizable,
                action: viewModel.toggleRuntimeWindowResizable
            )
        }
    }

    @ViewBuilder
    private func settingsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        if viewModel.showsPage(title) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.blue)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("AdaEditor.Settings.Group.\(title)")
                Divider()
                content()
            }
        }
    }

    private func settingsRow<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder control: @escaping () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(theme.editorColors.text)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
                    .lineLimit(1)
            }
            Spacer()
            control()
        }
        .padding(.vertical, 8)
    }

    private func settingsField(_ placeholder: String, detail: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
            TextField(placeholder, text: text)
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.text)
                .padding(.horizontal, 10)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 34, maxHeight: 34)
                .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
                .overlay {
                    RoundedRectangleShape(cornerRadius: 6).stroke(theme.editorColors.border, lineWidth: 1)
                }
                .textFieldStyle(PlainTextFieldStyle())
        }
    }

    private func selectionButton(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(selected ? theme.editorColors.text : theme.editorColors.muted)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangleShape(cornerRadius: 6)
                        .fill(selected ? theme.editorColors.blue.opacity(0.22) : theme.editorColors.surface)
                )
        }
        .buttonStyle(DefaultButtonStyle())
    }
}
