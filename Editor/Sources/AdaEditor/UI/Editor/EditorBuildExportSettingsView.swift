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
            Text(platform.detail)
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.muted)
            Text("Tool paths apply to this computer, across all projects. Leave a field empty to use automatic discovery.")
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.muted)
            if !EditorDistribution.current.supportsSwiftProjects {
                Text("External build tools require standalone desktop Studio.")
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
    }

    private func toolField(_ field: EditorBuildToolField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.title).font(.system(size: 12, weight: .bold))
            HStack(spacing: 8) {
                TextField(field.kind == .identifier ? "Identifier / version" : "Automatic", text: model.buildToolBinding(field.id, platform: platform))
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surfaceElevated))
                    .accessibilityIdentifier("AdaEditor.BuildExport." + platform.rawValue + "." + field.id)
                #if os(macOS)
                if field.kind != .identifier {
                    Button("Browse…") { browse(field) }
                        .font(.system(size: 12))
                        .frame(width: 88, height: 34)
                        .accessibilityIdentifier("AdaEditor.BuildExport.Browse." + platform.rawValue + "." + field.id)
                }
                #endif
            }
            .disabled(!EditorDistribution.current.supportsSwiftProjects)
            Text(model.buildExportConfiguration.pathStatus(field, for: platform))
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
        panel.prompt = "Select"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.buildToolBinding(field.id, platform: platform).wrappedValue = url.path
        }
    }
    #endif
}

extension EditorSettingsWindowViewModel {
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
        buildExportConfiguration.save(defaults: buildExportDefaults)
        #if os(macOS)
        editorViewModel?.androidConfiguration = EditorAndroidConfiguration.load(
            engineRoot: EditorAndroidConfiguration.studioEngineRoot,
            preferences: buildExportDefaults.dictionary(forKey: EditorAndroidConfiguration.preferenceKey) as? [String: String]
        )
        editorViewModel?.refreshAndroidTargets()
        #endif
        buildExportSettingsStatusMessage = "Saved tool paths for this computer."
    }
}
