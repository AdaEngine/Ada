@_spi(AdaEngine) import AdaEngine
import Foundation
#if os(macOS)
import AppKit
#endif

struct EditorBuildExportSettingsView: View {
    let model: EditorSettingsWindowViewModel
    let platform: EditorBuildPlatform
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(platform.title + " Build Tools")
                .font(.system(size: 16, weight: .bold))
            Text(L10n.tr(platform.detail))
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.muted)
            Text(L10n.text("Tool paths apply to this computer, across all projects. Leave a field empty to use automatic discovery."))
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.muted)
            toolSetup
            if !EditorDistribution.current.supportsSwiftProjects {
                Text(L10n.text("External build tools require standalone desktop Studio."))
                    .font(.system(size: 12))
                    .foregroundColor(theme.editorColors.muted)
            }
            ForEach(platform.fields) { field in
                toolField(field)
            }
        }
        .padding(.top, 16)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("AdaEditor.BuildExport.Page." + platform.rawValue)
        .task { @MainActor in
            if !model.scannedBuildPlatforms.contains(platform) {
                await model.rescanBuildTools(for: platform)
            }
        }
        .onChange(of: platform) { _, next in
            Task { @MainActor in
                if !model.scannedBuildPlatforms.contains(next) {
                    await model.rescanBuildTools(for: next)
                }
            }
        }
    }

    private var toolSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(model.scanningBuildPlatforms.contains(platform) ? L10n.text("Scanning…") : L10n.text("Rescan")) {
                    Task { await model.rescanBuildTools(for: platform) }
                }
                .disabled(model.scanningBuildPlatforms.contains(platform))
                .accessibilityIdentifier("AdaEditor.BuildExport.Rescan." + platform.rawValue)
                if platform == .host || (platform == .android && EditorBuildPlatform.host != .windows) {
                    Button(L10n.text("Install Swift…")) { model.openBuildToolSetup(.swift) }
                        .accessibilityIdentifier("AdaEditor.BuildExport.InstallSwift." + platform.rawValue)
                }
                if platform == .android {
                    Button(L10n.text("Install Android SDK…")) { model.openBuildToolSetup(.android) }
                        .accessibilityIdentifier("AdaEditor.BuildExport.InstallAndroid")
                }
            }
            .buttonStyle(EditorBuildToolButtonStyle(theme: theme))
            .disabled(!EditorDistribution.current.supportsSwiftProjects)
            Text(L10n.text("Install opens the official setup page in your browser. Finish installation, then Rescan and Save Build Settings."))
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
            if platform == .android {
                Text(L10n.text("In Android Studio, use SDK Manager to install Platform-Tools, Build-Tools, Emulator and NDK (Side by side). The bundled JDK is detected automatically."))
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
            }
            #if os(Windows)
            if platform == .android || platform == .web {
                Text(L10n.text("Web and Android compilation also require the WSL export tools. Native Windows Swift is used for Windows projects."))
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
            }
            #endif
        }
    }

    private func toolField(_ field: EditorBuildToolField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr(field.title)).font(.system(size: 12, weight: .bold))
            HStack(spacing: 8) {
                TextField(field.kind == .identifier ? L10n.text("Identifier / version") : L10n.text("Automatic"), text: model.buildToolBinding(field.id, platform: platform))
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surfaceElevated))
                    .accessibilityIdentifier("AdaEditor.BuildExport." + platform.rawValue + "." + field.id)
                #if os(macOS) || os(Windows)
                if field.kind != .identifier {
                    Button(L10n.text("Browse…")) { browse(field) }
                        .buttonStyle(EditorBuildToolButtonStyle(theme: theme, height: 34, width: 88))
                        .accessibilityIdentifier("AdaEditor.BuildExport.Browse." + platform.rawValue + "." + field.id)
                }
                #endif
            }
            .disabled(!EditorDistribution.current.supportsSwiftProjects)
            Text(L10n.tr(model.buildToolStatus(field, platform: platform)))
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    #if os(macOS)
    private func browse(_ field: EditorBuildToolField) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = field.kind == .executable
        panel.canChooseDirectories = field.kind == .directory
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = L10n.tr("Select")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.buildToolBinding(field.id, platform: platform).wrappedValue = url.path
        }
    }
    #endif

    #if os(Windows)
    private func browse(_ field: EditorBuildToolField) {
        Task { @MainActor in
            let url: URL?
            if field.kind == .directory {
                switch await WindowsProjectFilePicker.folder(title: L10n.text("Choose \(L10n.tr(field.title))")) {
                case .selected(let selected): url = selected
                default: url = nil
                }
            } else {
                switch await WindowsProjectFilePicker.files(title: L10n.text("Choose \(L10n.tr(field.title))"), allowsMultipleSelection: false) {
                case .selected(let selected): url = selected.first
                default: url = nil
                }
            }
            if let url { model.buildToolBinding(field.id, platform: platform).wrappedValue = url.path }
        }
    }
    #endif
}

private struct EditorBuildToolButtonStyle: ButtonStyle {
    let theme: Theme
    var height: Float = 30
    var width: Float?

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = configuration.state.isEnabled
            && (configuration.isHighlighted || configuration.isPressed || configuration.state.contains(.focused))
        let shape = RoundedRectangleShape(cornerRadius: 5)
        return configuration.label
            .font(.system(size: 12))
            .foregroundColor(theme.editorColors.text)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minWidth: 68)
            .frame(width: width, height: height)
            .background(shape.fill(theme.editorColors.surface))
            .overlay {
                shape.fill(highlighted ? theme.editorColors.text.opacity(0.10) : .clear)
            }
            .overlay { shape.stroke(theme.editorColors.border, lineWidth: 1) }
            .opacity(configuration.state.isEnabled ? 1 : 0.45)
    }
}

extension EditorSettingsWindowViewModel {
    func rescanBuildTools(for platform: EditorBuildPlatform) async {
        guard EditorDistribution.current.supportsSwiftProjects, !scanningBuildPlatforms.contains(platform) else { return }
        scanningBuildPlatforms.insert(platform)
        defer { scanningBuildPlatforms.remove(platform) }
        let snapshot = buildExportConfiguration
        // Select dependent tools (NDK/build-tools) from this SDK, including unsaved edits.
        let overrides = Dictionary(uniqueKeysWithValues: platform.fields.compactMap { field -> (String, String)? in
            let value = snapshot.normalizedValue(field, for: platform)
            guard !value.isEmpty, field.kind != .identifier,
                  EditorBuildToolDiscovery.isAvailable(value, key: field.id) else { return nil }
            return (field.id, value)
        })
        let found = await buildToolDiscovery.scan(overrides: overrides)
        let updated = buildExportConfiguration.applyDiscoveredTools(found, for: platform, unchangedSince: snapshot)
        scannedBuildPlatforms.insert(platform)
        buildExportSettingsStatusMessage = updated > 0
            ? "Found \(updated) tool paths or versions. Save Build Settings to apply."
            : "Scan complete. Existing paths kept; unavailable tools need installation or Browse…."
    }

    func buildToolStatus(_ field: EditorBuildToolField, platform: EditorBuildPlatform) -> String {
        let value = buildExportConfiguration.normalizedValue(field, for: platform)
        #if os(Windows)
        if platform == .web, field.kind != .identifier {
            return value.isEmpty ? "Automatic in WSL — checked when building."
                : "WSL override — checked when building, not on Windows."
        }
        if platform == .android, ["SWIFT_ANDROID_SWIFT", "SWIFT_ANDROID_SDKS_PATH", "ADAENGINE_SWAN_PACKAGE_PATH", "SWAN_LOCAL_DAWN"].contains(field.id) {
            return "Provided by the WSL export tools on Windows."
        }
        #endif
        if field.kind != .identifier, scannedBuildPlatforms.contains(platform), value.isEmpty {
            return "Not found — install the tool or choose its path with Browse…."
        }
        if field.kind != .identifier, !value.isEmpty, !EditorBuildToolDiscovery.isAvailable(value, key: field.id) {
            return "Unavailable — path or required tool is missing."
        }
        return buildExportConfiguration.pathStatus(field, for: platform)
    }

    func openBuildToolSetup(_ tool: EditorBuildToolSetup) {
        guard let url = URL(string: tool.address), Application.shared?.openURL(url) == true else {
            buildExportSettingsStatusMessage = "Could not open the browser. Visit " + tool.address
            return
        }
        buildExportSettingsStatusMessage = "Finish installation in the browser, then Rescan and Save Build Settings."
    }

    func buildToolBinding(_ key: String, platform: EditorBuildPlatform) -> Binding<String> {
        Binding(
            get: { self.buildExportConfiguration.value(key, for: platform) },
            set: {
                self.buildExportConfiguration.values[platform.rawValue, default: [:]][key] = $0
                self.buildExportSettingsStatusMessage = ""
            }
        )
    }

    func applyBuildExportSettings() {
        guard EditorDistribution.current.supportsSwiftProjects else { return }
        guard buildExportConfiguration.save(defaults: buildExportDefaults) else {
            buildExportSettingsStatusMessage = "Could not save tool paths to disk. Check access to your user preferences and try again."
            return
        }
        #if os(macOS) || os(Windows) || os(Linux)
        editorViewModel?.androidConfiguration = EditorAndroidConfiguration.load(
            engineRoot: EditorAndroidConfiguration.studioEngineRoot,
            preferences: buildExportDefaults.dictionary(forKey: EditorAndroidConfiguration.preferenceKey) as? [String: String]
        )
        editorViewModel?.refreshAndroidTargets()
        #endif
        buildExportSettingsStatusMessage = "Saved tool paths for this computer."
    }
}
