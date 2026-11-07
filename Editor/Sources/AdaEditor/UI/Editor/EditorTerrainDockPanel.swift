@_spi(AdaEngine) import AdaEngine
import Foundation

/// Terrain authoring occupies the bottom of its scene viewport, independently of the Inspector.
struct EditorTerrainDockPanel: View {
    let state: EditorTerrainEditingState
    let onChange: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L10n.text("Terrain")).font(.system(size: 12, weight: .semibold))
                tab("Sculpt", tool: .sculpt)
                tab("Materials", tool: .paint)
                tab("Joining", tool: .sculpt)
                tab("Mesh Instancing", tool: .scatter)
                tab("Height Generator", tool: .sculpt)
                Spacer()
                if let status = state.sourceStatus { Text(L10n.tr(status)).font(.system(size: 11)).foregroundColor(theme.editorColors.muted).lineLimit(1) }
            }
            creationControls
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    if state.dockTab != "Joining" {
                        VStack(alignment: .leading, spacing: 9) {
                        Text(L10n.text("Brush Settings")).font(.system(size: 11, weight: .semibold))
                        slider("Brush Radius", value: Binding(get: { Double(state.radius) }, set: { state.radius = Float($0); onChange() }), range: 0.5...32, id: "Radius")
                        slider("Brush Strength", value: Binding(get: { Double(state.strength) }, set: { state.strength = Float($0); onChange() }), range: 0.2...12, id: "Strength")
                        Text(L10n.text("Drag to draw. Escape cancels. Undo restores the previous surface."))
                            .font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
                        }.frame(width: 220)
                    }
                    if state.dockTab == "Joining" {
                        EditorMeshTerrainJoiningPanel(state: state, onChange: onChange)
                    } else if state.dockTab == "Sculpt" {
                        sculptTools
                    } else if state.dockTab == "Materials" {
                        materialTools
                    } else if state.dockTab == "Mesh Instancing" {
                        meshTools
                    } else {
                        generatorTools
                    }
                }
            }
        }
        .padding(12)
        .font(.system(size: 11))
        .foregroundColor(theme.editorColors.text)
        .background(theme.editorColors.surface)
        .frame(height: dockHeight)
        .accessibilityIdentifier("AdaEditor.Terrain.Dock")
    }

    private var creationControls: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Text(L10n.text("Terrain Type")).font(.system(size: 11))
                EditorEnumField(cases: EditorTerrainCreationBackend.allCases.map(\.rawValue), selection: Binding(
                    get: { state.creationBackend.rawValue },
                    set: { if let value = EditorTerrainCreationBackend(rawValue: $0) { state.creationBackend = value } }
                ), accessibilityID: "AdaEditor.Terrain.Backend").frame(width: 170)
                Button(action: { state.sourceActions?.create() }) {
                    Text(L10n.text("Create Terrain")).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: controlHeight)
                }
                .buttonStyle(EditorFieldButtonStyle(theme: theme))
                .accessibilityIdentifier("AdaEditor.Terrain.Create")
            }
            .disabled(state.isSourceBusy)
        }
    }

    private var controlHeight: Float {
        #if IOS || VISIONOS || ANDROID
        44
        #else
        30
        #endif
    }

    private var dockHeight: Float {
        #if IOS || VISIONOS || ANDROID
        300
        #else
        274
        #endif
    }

    private var sculptTools: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                mode(.raise); mode(.lower); mode(.smooth); mode(.flatten)
            }
            Text(L10n.text("Brush Preset")).font(.system(size: 11))
            EditorEnumField(
                cases: EditorTerrainBrushPreset.all.map(\.name),
                selection: Binding(
                    get: { state.sourcePresetName.isEmpty ? "Soft hill" : state.sourcePresetName },
                    set: { name in
                        state.sourcePresetName = name
                        if let preset = EditorTerrainBrushPreset.all.first(where: { $0.name == name }) {
                            state.radius = preset.radius; state.strength = preset.strength
                        }
                        onChange()
                    }
                ),
                accessibilityID: "AdaEditor.Terrain.Preset"
            )
            Button(L10n.text("Add region")) { state.sourceActions?.extend() }.disabled(state.isSourceBusy)
        }.frame(width: 400)
    }

    private var materialTools: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Button(L10n.text("Add Material…")) { state.sourceActions?.texture() }
                    .disabled(state.isSourceBusy).accessibilityIdentifier("AdaEditor.Terrain.AddMaterial")
                Button(L10n.text("Automatic Grass / Rock / Snow")) { state.sourceActions?.materials() }.disabled(state.isSourceBusy)
                Toggle(L10n.text("Reduce texture repetition"), isOn: Binding(
                    get: { state.usesTextureVariation },
                    set: { state.usesTextureVariation = $0; state.sourceActions?.variation() }
                )).disabled(state.isSourceBusy)
                Button(L10n.text("Erase material paint")) { state.sourceTool = .erasePaint; onChange() }
                Text(L10n.text("Height and slope choose automatic layers. Paint overrides them."))
                    .font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
            }.frame(width: 200)
            ForEach(state.sourceManifest?.materials?.layers ?? [], id: \.id) { layer in
                Button(action: { state.sourceLayerID = layer.id; state.sourceTool = .paint; onChange() }) {
                    EditorTerrainMaterialCard(layer: layer, folder: state.sourceAssetFolder, selected: state.sourceLayerID == layer.id)
                }.buttonStyle(DefaultButtonStyle()).accessibilityIdentifier("AdaEditor.Terrain.Material.\(layer.id)")
            }
        }
    }

    private var meshTools: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(L10n.text("Paint meshes")) { state.sourceTool = .scatter; onChange() }
                    Button(L10n.text("Erase meshes")) { state.sourceTool = .eraseMeshes; onChange() }
                }
                Button(L10n.text("Add Mesh…")) { state.sourceActions?.mesh() }
                    .disabled(state.isSourceBusy).accessibilityIdentifier("AdaEditor.Terrain.AddMesh")
                slider("Mesh Density", value: Binding(get: { state.meshDensity }, set: { state.meshDensity = $0 }), range: 0.01...1, id: "Density")
                Text(L10n.text("Import a self-contained GLB or VOX model. Copies share mesh buffers."))
                    .font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
            }.frame(width: 250)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(state.sourceManifest?.meshPrototypes ?? [], id: \.id) { mesh in
                    Button(action: { state.sourcePrototypeID = mesh.id; state.sourceTool = .scatter; onChange() }) {
                        Text("#\(mesh.id) · \(mesh.assetPath)").font(.system(size: 10)).lineLimit(1)
                            .padding(6).background(theme.editorColors.blue.opacity(state.sourcePrototypeID == mesh.id ? 0.25 : 0.05))
                    }.buttonStyle(DefaultButtonStyle())
                }
            }.frame(width: 230)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(L10n.text("Add solid")) { state.sourceTool = .add; onChange() }
                    Button(L10n.text("Subtract solid")) { state.sourceTool = .subtract; onChange() }
                }
                EditorEnumField(cases: ["Sphere", "Box", "Capsule", "Palette mesh"], selection: Binding(get: { state.volumeOperand }, set: { state.volumeOperand = $0 }))
            }.frame(width: 220)
        }
    }

    private var generatorTools: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                slider("Height Amplitude", value: Binding(get: { Double(state.noise.amplitude) }, set: { state.noise.amplitude = Float($0) }), range: 0...40, id: "NoiseAmplitude")
                slider("Noise Frequency", value: Binding(get: { Double(state.noise.frequency) }, set: { state.noise.frequency = Float($0) }), range: 0.005...0.15, id: "NoiseFrequency")
            }.frame(width: 250)
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("Five noise octaves generate hills and valleys."))
                    .font(.system(size: 11))
                Text(L10n.text("Seed: \(state.noise.seed)")).font(.system(size: 11))
                Button(L10n.text("New Seed")) { state.noise.seed &+= 1 }
                Button(L10n.text("Generate Heightmap")) { state.sourceActions?.generate() }
                    .disabled(state.isSourceBusy).accessibilityIdentifier("AdaEditor.Terrain.Generate")
            }.frame(width: 300)
        }
    }

    private func tab(_ title: String, tool: EditorTerrainTool) -> some View {
        Button(action: {
            if state.dockTab != title {
                if state.sourceStroke != nil || state.stroke != nil || state.meshSculptPointerActive { state.sourceActions?.cancel?() }
                state.sourceHoverTask?.cancel()
                state.hover = nil
            }
            state.dockTab = title; state.sourceTool = tool; onChange()
        }) {
            Text(L10n.tr(title)).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                .background(theme.editorColors.blue.opacity(state.dockTab == title ? 0.25 : 0.04))
        }.buttonStyle(DefaultButtonStyle()).accessibilityIdentifier("AdaEditor.Terrain.Tab.\(title)")
    }

    private func mode(_ mode: EditorTerrainBrushMode) -> some View {
        Button(action: { state.mode = mode; state.sourcePresetName = ""; state.sourceTool = .sculpt; onChange() }) {
            Text(L10n.tr(mode.rawValue)).font(.system(size: 11)).padding(7)
                .background(theme.editorColors.blue.opacity(state.mode == mode ? 0.25 : 0.05))
        }.buttonStyle(DefaultButtonStyle()).accessibilityIdentifier("AdaEditor.Terrain.Mode.\(mode.rawValue)")
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(L10n.tr(title)); Spacer(); Text(String(format: "%.2f", value.wrappedValue)) }.font(.system(size: 10))
            Slider(value: value, in: range).accessibilityIdentifier("AdaEditor.Terrain.\(id)")
        }
    }
}

private struct EditorTerrainMaterialCard: View {
    let layer: TerrainLayerReference
    let folder: URL?
    let selected: Bool
    @State private var preview: Image?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Color(red: layer.tint.x, green: layer.tint.y, blue: layer.tint.z)
                if let preview { preview.resizable().frame(width: 86, height: 76) }
            }.frame(width: 86, height: 76)
            Text(layer.name).font(.system(size: 10)).lineLimit(1)
        }
        .padding(6)
        .frame(width: 100)
        .background(theme.editorColors.blue.opacity(selected ? 0.25 : 0.05))
        .task { await loadPreview() }
        .onChange(of: layer.albedoPath) { _, _ in loadPreview() }
    }

    private func loadPreview() {
        preview = layer.albedoPath.flatMap { path in folder.flatMap { try? Image(contentsOf: $0.appendingPathComponent(path)) } }
    }
}
