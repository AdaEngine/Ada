import AdaEngine

struct EditorMovieMakerDialog: View {
    let model: EditorMovieMakerModel
    let canStart: Bool
    let onStart: () -> Void
    let onBrowse: () -> Void
    let onClose: () -> Void
    let onReveal: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.text("Movie Maker"))
                        .font(.system(size: 20, weight: .semibold))
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(L10n.text("Record game cameras as lossless PNG frames and synchronized WAV audio."))
                                .font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
                            settings
                                .disabled(model.isBusy)
                            status
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 12) {
                        action("Close", id: "Close", primary: false, onClose)
                        Spacer()
                        if model.isBusy {
                            action("Stop Recording", id: "Stop", primary: true, model.stop)
                                .disabled(model.phase == .stopping)
                        } else {
                            action("Start Recording", id: "Start", primary: true, onStart)
                                .disabled(!canStart || model.validationMessage != nil)
                        }
                    }
                }
                .padding(20)
                .frame(width: min(520, max(0, geometry.size.width - 32)), height: min(660, max(0, geometry.size.height - 32)))
                .foregroundColor(theme.editorColors.text)
                .background(RoundedRectangleShape(cornerRadius: 12).fill(theme.editorColors.surfaceElevated))
                .overlay { RoundedRectangleShape(cornerRadius: 12).stroke(theme.editorColors.border, lineWidth: 1) }
                .accessibilityIdentifier("AdaEditor.MovieMaker.Dialog")
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .keyboardShortcuts([KeyboardShortcutAction(.escape, action: onClose)])
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Record"))
            HStack(spacing: 8) {
                ForEach(EditorMovieMakerTarget.allCases, id: \.self) { target in
                    Button(L10n.tr(target.title)) { model.settings.target = target }
                        .buttonStyle(DefaultButtonStyle())
                        .padding(8)
                        .foregroundColor(model.settings.target == target ? theme.editorColors.blue : theme.editorColors.muted)
                        .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
                        .accessibilityIdentifier("AdaEditor.MovieMaker.Target.\(target.rawValue)")
                }
            }
            field("FPS", key: \.framesPerSecond, id: "FPS")
            HStack(spacing: 10) {
                field("Width", key: \.width, id: "Width")
                field("Height", key: \.height, id: "Height")
            }
            HStack(spacing: 8) {
                resolution("720p", width: "1280", height: "720")
                resolution("1080p", width: "1920", height: "1080")
                resolution("4K", width: "3840", height: "2160")
            }
            field("Duration (seconds)", key: \.duration, id: "Duration")
            field("Save path (.png)", key: \.outputPath, id: "Path")
            Button(L10n.text("Choose Folder…"), action: onBrowse)
                .foregroundColor(theme.editorColors.blue)
                .accessibilityIdentifier("AdaEditor.MovieMaker.Browse")
            Toggle(L10n.text("Record game audio"), isOn: Binding(
                get: { model.settings.includesAudio }, set: { model.settings.includesAudio = $0 }
            ))
            .accessibilityIdentifier("AdaEditor.MovieMaker.Audio")
            Text(L10n.text("Relative paths start in the project folder. Existing takes are kept."))
                .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
        }
        .font(.system(size: 12))
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.statusText).font(.system(size: 12))
                .accessibilityIdentifier("AdaEditor.MovieMaker.Status")
            if model.isBusy {
                GeometryReader { geometry in
                    ZStack(anchor: .leading) {
                        theme.editorColors.surface
                        theme.editorColors.blue.frame(width: geometry.size.width * model.progress)
                    }
                }.frame(height: 5)
                .accessibilityIdentifier("AdaEditor.MovieMaker.Progress")
            }
            if let error = model.errorMessage ?? model.validationMessage {
                Text(error).font(.system(size: 12)).foregroundColor(.red)
                    .accessibilityIdentifier("AdaEditor.MovieMaker.Error")
            }
            if model.phase == .completed || (model.phase == .cancelled && model.savedFrames > 0) {
                if let outputURL = model.outputURL {
                    Text(outputURL.path).font(.system(size: 11)).lineLimit(2)
                }
                Button(L10n.text("Show Movie Files"), action: onReveal)
                    .foregroundColor(theme.editorColors.blue)
                    .accessibilityIdentifier("AdaEditor.MovieMaker.Reveal")
            }
        }
    }

    private func field(_ title: String, key: WritableKeyPath<EditorMovieMakerSettings, String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.tr(title)).font(.system(size: 12))
            TextField("", text: Binding(get: { model.settings[keyPath: key] }, set: { model.settings[keyPath: key] = $0 }))
                .font(.system(size: 12))
                .textFieldStyle(PlainTextFieldStyle())
                .padding(.horizontal, 8).frame(height: 32)
                .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
                .overlay { RoundedRectangleShape(cornerRadius: 6).stroke(theme.editorColors.border, lineWidth: 1) }
                .accessibilityIdentifier("AdaEditor.MovieMaker.\(id)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resolution(_ title: String, width: String, height: String) -> some View {
        Button(L10n.tr(title)) { model.settings.width = width; model.settings.height = height }
            .buttonStyle(DefaultButtonStyle()).padding(6)
            .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
            .accessibilityIdentifier("AdaEditor.MovieMaker.Resolution.\(title)")
    }

    private func action(_ title: String, id: String, primary: Bool, _ action: @escaping () -> Void) -> some View {
        Button(L10n.tr(title), action: action)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(primary ? .white : theme.editorColors.text)
            .padding(.horizontal, 14).frame(height: 34)
            .background(RoundedRectangleShape(cornerRadius: 7).fill(primary ? theme.editorColors.blue : theme.editorColors.surface))
            .accessibilityIdentifier("AdaEditor.MovieMaker.\(id)")
    }
}
