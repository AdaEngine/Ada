#if os(macOS)
  import AdaEngine
  import Foundation

  struct EditorAndroidSettingsView: View {
    let editor: EditorViewModel?
    @State private var values: [String: String] = EditorAndroidConfiguration.load(
      engineRoot: EditorAndroidConfiguration.studioEngineRoot
    ).environment
    @State private var status = ""
    @Environment(\.theme) private var theme

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        Text("Android Build Tools").font(.system(size: 16, weight: .bold))
        Text(
          "Export APKs and run on Android emulators or devices. Requires Swift 6.4, its matching Android SDK, Android SDK/NDK and a Swan Android Dawn artifact."
        )
        .font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
        ForEach(EditorAndroidConfiguration.fields.map(\.0), id: \.self) { key in
          VStack(alignment: .leading, spacing: 4) {
            Text(EditorAndroidConfiguration.fields.first(where: { $0.0 == key })?.1 ?? key).font(
              .system(size: 12, weight: .bold))
            TextField(
              "Path or identifier",
              text: Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
            )
            .font(.system(size: 12)).accessibilityIdentifier("AdaEditor.Android.Settings." + key)
          }
        }
        Button("Save Android Settings") {
          UserDefaults.standard.set(
            Dictionary(
              uniqueKeysWithValues: EditorAndroidConfiguration.fields.map {
                ($0.0, values[$0.0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
              }),
            forKey: EditorAndroidConfiguration.preferenceKey)
          editor?.androidConfiguration = EditorAndroidConfiguration.load(
            engineRoot: EditorAndroidConfiguration.studioEngineRoot)
          editor?.refreshAndroidTargets()
          status = "Android settings saved."
        }
        .accessibilityIdentifier("AdaEditor.Android.Settings.Save")
        if !status.isEmpty {
          Text(status).font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
        }
      }
      .padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
#endif
