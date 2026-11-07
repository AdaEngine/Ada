@_spi(AdaEngine) import AdaEngine
import Foundation

/// Uses the same fields/buttons as inspectors; the owning dock supplies horizontal scrolling.
struct EditorMeshTerrainJoiningPanel: View {
    let state: EditorTerrainEditingState
    let onChange: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("Selected object")).font(.system(size: 11, weight: .semibold))
                Text(state.meshSourceName ?? L10n.text("Select a static mesh in the scene.")).font(.system(size: 12)).lineLimit(2)
                Text(L10n.text("The object stays in the hierarchy. Move it to update the terrain and surrounding objects."))
                    .font(.system(size: 10)).foregroundColor(theme.editorColors.muted).lineLimit(4)
            }.frame(width: 220)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Target Terrain")).font(.system(size: 11, weight: .semibold))
                DropDown(selection: Binding(get: { state.meshTargetEditorID ?? state.meshTargets.first?.id ?? "" },
                    set: { if !state.isSourceBusy { state.meshTargetEditorID = $0; onChange() } }),
                    options: state.meshTargets.map { .init(label: $0.name, value: $0.id) }, identifier: "AdaEditor.Terrain.JoinTarget") {
                    HStack(spacing: 6) {
                        Text(targetName).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        Text("\u{E5CF}").environment(\.font, AdaEditorMaterialSymbolFont.font(size: 16))
                    }.padding(.horizontal, 8).frame(height: controlHeight)
                }
                .buttonStyle(EditorFieldButtonStyle(theme: theme))
                .disabled(state.isSourceBusy || state.meshTargets.isEmpty)
                Text(L10n.text("Operation")).font(.system(size: 11, weight: .semibold))
                EditorEnumField(cases: ["Join", "Subtract", "Conform"],
                    selection: Binding(get: { state.meshOperation }, set: { if !state.isSourceBusy { state.meshOperation = $0; onChange() } }),
                    accessibilityID: "AdaEditor.Terrain.JoinOperation").disabled(state.isSourceBusy)
                if state.meshOperation == "Conform" {
                    setting("Projection distance", property: \.meshConformDistance, in: 0.1...16, id: "ConformDistance")
                    setting("Projection strength", property: \.meshConformStrength, in: 0...1, id: "ConformStrength")
                } else if state.meshOperation == "Join" {
                    setting("Contact width", property: \.meshContactWidth, in: 0...8, id: "JoinContactWidth")
                }
            }.frame(width: 240)
            VStack(alignment: .leading, spacing: 10) {
                Button(action: {
                    // Observable changes schedule visual reconciliation. Reject a queued click
                    // against the live state as well, including the interval before that frame.
                    guard !state.isSourceBusy, state.meshSourceName != nil, !state.meshTargets.isEmpty else { return }
                    state.sourceActions?.join?()
                }) {
                    Text(state.meshOperation == "Join" ? L10n.text("Join selected mesh") : L10n.text("Apply operation")).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: controlHeight).frame(maxWidth: .infinity)
                }
                .buttonStyle(EditorFieldButtonStyle(theme: theme))
                .disabled(state.isSourceBusy || state.meshSourceName == nil || state.meshTargets.isEmpty)
                .accessibilityIdentifier("AdaEditor.Terrain.JoinSelected")
                if state.meshHasBinding {
                    EditorMeshTerrainDetachButton(state: state, accessibilityID: "AdaEditor.Terrain.DetachSelected") {
                        if state.meshHasBinding { state.sourceActions?.detach?() }
                    }
                }
                if state.isSourceBusy {
                    Button(action: { state.sourceActions?.cancel?() }) {
                        Text(L10n.text("Cancel")).font(.system(size: 11)).padding(.horizontal, 10)
                            .frame(height: controlHeight).frame(maxWidth: .infinity)
                    }.buttonStyle(EditorFieldButtonStyle(theme: theme)).accessibilityIdentifier("AdaEditor.Terrain.Cancel")
                }
                if let status = state.sourceStatus {
                    Text(L10n.tr(status)).font(.system(size: 11)).lineLimit(2)
                }
                if let failure = state.sourceFailure {
                    Text(L10n.tr(failure)).font(.system(size: 10)).lineLimit(4)
                }
                Text(L10n.text("Escape cancels. Undo restores the whole change."))
                    .font(.system(size: 10)).foregroundColor(theme.editorColors.muted).lineLimit(2)
            }.frame(width: 240)
        }
    }

    private var targetName: String {
        state.meshTargets.first { $0.id == state.meshTargetEditorID }?.name ?? state.meshTargets.first?.name ?? L10n.text("No Mesh Terrain is ready.")
    }

    private func setting(_ title: String, property: ReferenceWritableKeyPath<EditorTerrainEditingState, Float>,
                         in range: ClosedRange<Double>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.tr(title))
                Spacer()
                Text(String(format: "%.2f", state[keyPath: property]))
            }.font(.system(size: 10))
            Slider(value: Binding(get: { Double(state[keyPath: property]) }, set: {
                guard !state.isSourceBusy else { return }
                state[keyPath: property] = Float($0); onChange()
            }), in: range)
            .disabled(state.isSourceBusy)
            .accessibilityIdentifier("AdaEditor.Terrain.\(id)")
        }
    }

    private var controlHeight: Float {
        #if IOS || VISIONOS || ANDROID
        44
        #else
        30
        #endif
    }
}

struct EditorMeshTerrainDetachButton: View {
    let state: EditorTerrainEditingState
    let accessibilityID: String
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: {
            guard !state.isSourceBusy else { return }
            action()
        }) {
            Text(L10n.text("Detach from terrain")).font(.system(size: 11))
                .padding(.horizontal, 10).frame(height: height).frame(maxWidth: .infinity)
        }
        .buttonStyle(EditorFieldButtonStyle(theme: theme))
        .disabled(state.isSourceBusy)
        .accessibilityIdentifier(accessibilityID)
    }

    private var height: Float {
        #if IOS || VISIONOS || ANDROID
        44
        #else
        30
        #endif
    }
}
