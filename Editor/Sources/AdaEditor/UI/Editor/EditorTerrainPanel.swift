@_spi(AdaEngine) import AdaEngine
import Foundation

/// Contextual brush settings, sized for the Inspector's existing scroll column.
struct EditorTerrainPanel: View {
    let state: EditorTerrainEditingState
    let onCreate: () -> Void
    var onChange: () -> Void = {}
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                modeButton(.raise)
                modeButton(.lower)
            }
            HStack(spacing: 6) {
                modeButton(.smooth)
                modeButton(.flatten)
            }
            sliderRow(title: "Brush Radius", value: radiusBinding, range: 1...16, identifier: "Radius")
            sliderRow(title: "Brush Strength", value: strengthBinding, range: 0.2...12, identifier: "Strength")
            Button(action: onCreate) {
                Text(L10n.text("Create Terrain"))
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(theme.editorColors.blue.opacity(0.16))
            }
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.Terrain.Create")
            Text(L10n.text("Drag on the ground to shape it. Escape cancels the stroke."))
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundColor(theme.editorColors.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("AdaEditor.Terrain.Panel")
    }

    private var radiusBinding: Binding<Double> {
        Binding(get: { Double(state.radius) }, set: { state.radius = Float($0); onChange() })
    }

    private var strengthBinding: Binding<Double> {
        Binding(get: { Double(state.strength) }, set: { state.strength = Float($0); onChange() })
    }

    private func modeButton(_ mode: EditorTerrainBrushMode) -> some View {
        Button(action: { state.mode = mode; onChange() }) {
            Text(L10n.tr(mode.rawValue))
                .font(.system(size: 11))
                .foregroundColor(state.mode == mode ? theme.editorColors.text : theme.editorColors.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(theme.editorColors.blue.opacity(state.mode == mode ? 0.25 : 0.06))
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.Terrain.Mode.\(mode.rawValue)")
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.tr(title)).font(.system(size: 11))
                Spacer()
                Text(String(format: "%.1f", value.wrappedValue))
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
            }
            Slider(value: value, in: range)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("AdaEditor.Terrain.\(identifier)")
        }
    }
}
