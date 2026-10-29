@_spi(AdaEngine) import AdaEngine
import Foundation

/// One slider row per named morph target. Shared by the Animator panel and its tests.
struct EditorMorphWeightList: View {
    let model: EditorMorphTargetsModel
    var onChange: () -> Void = {}
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.targets, id: \.name) { target in
                    row(target)
                }
            }
            .padding(4)
        }
        .accessibilityIdentifier("AdaEditor.Morph.List")
    }

    private func row(_ target: EditorMorphTargetsModel.Target) -> some View {
        HStack(spacing: 8) {
            Text(target.name)
                .font(.system(size: 11, weight: model.weights[target.name] == nil ? .regular : .semibold))
                .frame(width: 130, alignment: .leading)
                .accessibilityIdentifier("AdaEditor.Morph.Name.\(target.name)")
            Slider(
                value: Binding(
                    get: { Double(model.weight(of: target)) },
                    set: { value in
                        model.setWeight(Float(value), for: target)
                        onChange()
                    }
                ),
                in: Double(EditorMorphTargetsModel.weightRange.lowerBound)...Double(EditorMorphTargetsModel.weightRange.upperBound)
            )
            .accessibilityIdentifier("AdaEditor.Morph.Slider.\(target.name)")
            Text(String(format: "%.2f", model.weight(of: target)))
                .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

/// Sets the morph weights a Model 3D reference starts with, with a live preview. Applying is one undoable scene transaction.
struct EditorMorphTargetsPanel: View {
    let viewModel: EditorViewModel
    let target: EditorSkeletalAnimationTarget
    @State private var model = EditorMorphTargetsModel()
    @State private var preview = EditorModelAssetPreviewModel()
    @State private var camera = EditorModelPreviewCamera()
    @State private var status = ""
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            toolbar
            if preview.isLoading {
                Text(L10n.text("Loading morph target model…")).font(.system(size: 12))
            } else if let error = preview.error {
                Text(error).font(.system(size: 12)).foregroundColor(.red)
            } else if preview.asset != nil {
                if model.targets.isEmpty {
                    Text(L10n.text("This model has no named morph targets."))
                        .font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
                        .accessibilityIdentifier("AdaEditor.Morph.Empty")
                } else {
                    HStack(spacing: 8) {
                        EditorModelPreviewViewport(model: preview, camera: camera)
                            .frame(width: 220, height: 150)
                        EditorMorphWeightList(model: model, onChange: { syncPreview() })
                    }
                    .frame(maxHeight: .infinity)
                }
                if model.unnamedTargetCount > 0 {
                    Text(L10n.text("Targets without a name cannot be set from a scene."))
                        .font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
                }
            }
            if !status.isEmpty { Text(status).font(.system(size: 11)).foregroundColor(theme.editorColors.muted) }
        }
        .padding(8)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { load() }
        .onDisappear { preview.cancel() }
        .onChange(of: target.source) { old, new in
            if old.source != new.source { load() } else { configure() }
        }
        .onChange(of: preview.asset.map(ObjectIdentifier.init)) { _, _ in configure() }
        .accessibilityIdentifier("AdaEditor.Animator.MorphTargets")
    }

    private var readOnly: Bool { viewModel.workbench.activeSceneDocument?.isReadOnly == true }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(L10n.text("MORPH TARGETS")).font(.system(size: 11, weight: .semibold))
            Spacer()
            action("Apply to Scene", id: "Apply") {
                if viewModel.workbench.setMorphWeights(model.weights, target: target) {
                    status = L10n.tr("Applied to scene. Save the scene to keep these weights.")
                }
            }
            .disabled(readOnly || model.targets.isEmpty || model.weights == target.source.morphWeights)
            action("Reset", id: "Reset") {
                model.reset()
                syncPreview()
                if viewModel.workbench.setMorphWeights([:], target: target) {
                    status = L10n.tr("Morph weights cleared.")
                }
            }
            .disabled(readOnly || (!model.hasAuthoredWeights && target.source.morphWeights.isEmpty))
        }
    }

    private func action(_ title: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(L10n.tr(title)).font(.system(size: 11)).padding(4) }
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.Morph.\(id)")
    }

    private func load() {
        do {
            let url = try EditorModelResource.resolve(target.source.source, sourceURL: target.sceneURL, resourceRootURL: viewModel.projectAssetsURL)
            preview.load(path: url.path)
        } catch {
            preview.isLoading = false
            preview.error = error.localizedDescription
        }
    }

    private func configure() {
        guard let asset = preview.asset else {
            return
        }
        model.configure(asset: asset, authored: target.source.morphWeights)
        syncPreview()
    }

    /// Every target gets its shown weight, so a reset puts the defaults back.
    private func syncPreview() {
        preview.morphWeights = Dictionary(uniqueKeysWithValues: model.targets.map { ($0.name, model.weight(of: $0)) })
    }
}
