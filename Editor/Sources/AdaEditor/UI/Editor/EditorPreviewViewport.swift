@_spi(AdaEngine) import AdaEngine
import Observation

@MainActor
@Observable
final class EditorPreviewControls {
    var zoom: Float = 1
    var isInteractive = false
}

struct EditorPreviewViewport: View {
    let previewView: UIView

    @Environment(\.theme) private var theme
    var settings = EditorPreviewControls()

    var body: some View {
        EditorPreviewSurface(
            previewView: previewView,
            zoom: settings.zoom,
            isInteractive: settings.isInteractive
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mask(RectangleShape())
        .overlay(anchor: .bottom) {
            controls
                .padding(.bottom, 12)
        }
        .background(theme.editorColors.background)
        .accessibilityIdentifier("AdaEditor.PreviewViewport")
    }

    private var controls: some View {
        HStack(spacing: 2) {
            Button(action: { adjustZoom(by: -0.25) }) {
                Text("\u{E15B}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 15))
                    .frame(width: 26, height: 26)
            }
            .disabled(settings.zoom <= 0.25)
            .accessibilityIdentifier("AdaEditor.PreviewViewport.ZoomOut")

            Button(action: { settings.zoom = 1 }) {
                Text(zoomLabel)
                    .font(.system(size: 10))
                    .frame(width: 46, height: 26)
            }
            .accessibilityIdentifier("AdaEditor.PreviewViewport.ZoomReset")

            Button(action: { adjustZoom(by: 0.25) }) {
                Text("\u{E145}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 15))
                    .frame(width: 26, height: 26)
            }
            .disabled(settings.zoom >= 3)
            .accessibilityIdentifier("AdaEditor.PreviewViewport.ZoomIn")

            Button(action: { settings.isInteractive.toggle() }) {
                Text(settings.isInteractive ? "Interactive" : "Static")
                    .font(.system(size: 10, weight: settings.isInteractive ? .bold : .regular))
                    .frame(width: 62, height: 26)
            }
            .accessibilityIdentifier("AdaEditor.PreviewViewport.Interactive")
        }
        .foregroundColor(theme.editorColors.text)
        .padding(.horizontal, 6)
        .frame(height: 32)
        .background(Capsule().fill(theme.editorColors.surfaceElevated.opacity(0.96)))
        .overlay {
            Capsule()
                .stroke(theme.editorColors.border.opacity(0.9), lineWidth: 1)
        }
        .accessibilityIdentifier("AdaEditor.PreviewViewport.Controls")
    }

    private var zoomLabel: String {
        "\(Int((settings.zoom * 100).rounded()))%"
    }

    private func adjustZoom(by delta: Float) {
        let steppedZoom = (settings.zoom * 4 + delta * 4).rounded() / 4
        settings.zoom = min(max(steppedZoom, 0.25), 3)
    }
}
