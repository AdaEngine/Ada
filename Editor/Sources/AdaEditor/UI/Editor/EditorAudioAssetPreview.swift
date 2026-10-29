import AdaEngine
import Foundation

struct EditorAudioAssetPreview: View {
    let document: EditorAssetDocument
    @State private var model: EditorAudioPreviewModel
    @Environment(\.theme) private var theme

    init(document: EditorAssetDocument, model: EditorAudioPreviewModel = EditorAudioPreviewModel()) {
        self.document = document
        self._model = State(wrappedValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.title)
                        .font(.system(size: 15))
                        .foregroundColor(theme.editorColors.text)
                    Text(document.assetReference ?? document.relativePath)
                        .font(.system(size: 11))
                        .foregroundColor(theme.editorColors.muted)
                }
                playbackControls
                VStack(alignment: .leading, spacing: 8) {
                    informationRow("Extension", document.fileExtension.uppercased())
                    if let byteCount = document.byteCount {
                        informationRow("Size", ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
                    }
                    if let modifiedAt = document.modifiedAt {
                        informationRow("Modified", modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.editorColors.background)
        .accessibilityIdentifier("AdaEditor.AudioPreview")
        .onDisappear { model.stop() }
    }

    private var playbackControls: some View {
        VStack(spacing: 16) {
            Text(L10n.tr("Audio preview"))
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(theme.editorColors.text)
            Text(L10n.tr(model.statusKey))
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.muted)
                .accessibilityIdentifier("AdaEditor.AudioPreview.Status")
            HStack(spacing: 12) {
                Button(L10n.tr(model.state == .playing ? "Pause" : "Listen")) {
                    model.togglePlayback(path: document.absolutePath)
                }
                .disabled(model.state == .loading || document.absolutePath == nil)
                .accessibilityIdentifier("AdaEditor.AudioPreview.Play")
                Button(L10n.tr("Stop")) { model.stop() }
                    .disabled(model.state == .stopped)
                    .accessibilityIdentifier("AdaEditor.AudioPreview.Stop")
            }
            HStack(spacing: 12) {
                Text(L10n.tr("Volume"))
                    .font(.system(size: 12))
                    .foregroundColor(theme.editorColors.muted)
                Slider(value: Binding(get: { model.volume }, set: { model.volume = $0 }))
                    .frame(maxWidth: 220)
                    .accessibilityIdentifier("AdaEditor.AudioPreview.Volume")
            }
            if let key = model.errorKey {
                Text(L10n.tr(key)).foregroundColor(.red)
            } else if model.errorDetail != nil {
                Text(L10n.tr("Unable to play this audio file.")).foregroundColor(.red)
            } else if let message = document.errorMessage {
                Text(message).foregroundColor(.red)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.surface))
    }

    private func informationRow(_ key: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(L10n.tr(key))
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
                .frame(width: 76, alignment: .leading)
            Text(value).font(.system(size: 11)).foregroundColor(theme.editorColors.text)
        }
    }
}
