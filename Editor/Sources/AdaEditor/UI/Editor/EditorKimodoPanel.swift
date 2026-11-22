@_spi(AdaEngine) import AdaEngine
#if os(Windows)
import Foundation
import Observation
#endif

struct EditorKimodoInstallationPresentation: ViewModifier {
    let viewModel: EditorViewModel

    func body(content: Content) -> some View {
        #if os(Windows)
        let model = viewModel.kimodoInstaller
        content.fullScreenCover(isPresented: Binding(get: { model.isPresented }, set: { model.isPresented = $0 })) {
            EditorKimodoInstallDialog(model: model)
        }
        #else
        content
        #endif
    }
}

#if os(Windows)
@Observable
@MainActor
final class EditorKimodoInstallModel {
    var isPresented = false
    private(set) var file: URL?
    private(set) var isBusy = false
    private(set) var verifiedVersion: String?
    private(set) var installed = false
    private(set) var message = ""

    func choosePackage() {
        guard !isBusy else {
            return
        }
        isBusy = true
        Task {
            defer { isBusy = false }
            let result = await WindowsProjectFilePicker.files(title: L10n.tr("Install Extension from File…"))
            guard case .selected(let files) = result, files.count == 1, let file = files.first else {
                return
            }
            self.file = file
            verifiedVersion = nil
            installed = false
            message = ""
            isPresented = true
            do {
                verifiedVersion = try await EditorKimodoRunner.shared.inspect(file).version
            } catch { message = L10n.tr(error.localizedDescription) }
        }
    }

    func install() {
        guard !isBusy, verifiedVersion != nil, let file else {
            return
        }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                _ = try await EditorKimodoRunner.shared.install(file)
                installed = true
                message = L10n.tr("Kimodo is installed. Open a supported model in Animator to generate movement.")
            } catch { message = L10n.tr(error.localizedDescription) }
        }
    }
}

private struct EditorKimodoInstallDialog: View {
    let model: EditorKimodoInstallModel
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.45)
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("Install Extension from File…")).font(.system(size: 16, weight: .semibold))
                    Text(model.file?.lastPathComponent ?? "Kimodo").font(.system(size: 12))
                    if let version = model.verifiedVersion {
                        Text(L10n.text("Kimodo \(version) · Publisher signature verified")).font(.system(size: 12))
                        Text(L10n.text("Requires Ubuntu on WSL 2, an NVIDIA GPU and access to Llama 3 on Hugging Face."))
                            .font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
                    }
                    if model.isBusy { Text(L10n.text("Checking Kimodo package…")).font(.system(size: 12)) }
                    if !model.message.isEmpty { Text(model.message).font(.system(size: 12)) }
                    HStack(spacing: 8) {
                        Spacer()
                        Button { model.isPresented = false } label: { Text(L10n.tr(model.installed ? "Close" : "Cancel")) }
                            .buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors))
                            .disabled(model.isBusy)
                        if !model.installed {
                            Button { model.install() } label: { Text(L10n.text("Install")) }
                                .buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors, selected: true))
                                .disabled(model.isBusy || model.verifiedVersion == nil)
                        }
                    }
                }
                .padding(16)
                .frame(width: max(0, min(480, geometry.size.width - 32)))
                .foregroundColor(theme.editorColors.text)
                .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.surfaceElevated))
                .overlay { RoundedRectangleShape(cornerRadius: 8).stroke(theme.editorColors.border, lineWidth: 1) }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .keyboardShortcuts([KeyboardShortcutAction(.escape) { if !model.isBusy { model.isPresented = false } }])
    }
}

struct EditorKimodoPanel: View {
    let workspace: EditorAnimationAssetWorkspace
    let close: () -> Void
    @Environment(\.theme) private var theme
    @State private var prompt = ""
    @State private var duration = "4"
    @State private var name = ""
    @State private var progress = EditorKimodoProgress()
    @State private var error = ""
    @State private var job: Task<Void, Never>?
    @State private var draft: AnimationLibrary?
    @State private var priorPlayback: (playing: Bool, time: Double)?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 8) {
                Text(workspace.document.title).font(.system(size: 12, weight: .semibold))
                if draft != nil {
                    field("Clip name", value: $name)
                    Text(L10n.text("Previewing generated animation")).font(.system(size: 12))
                } else {
                    field("Describe the movement", value: $prompt)
                    field("Duration in seconds", value: $duration)
                }
                if !progress.status.isEmpty { Text(progress.status).font(.system(size: 12)) }
                if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundColor(.red) }
                HStack(spacing: 8) {
                    action(draft == nil ? "Cancel" : "Discard") { close() }
                    if draft != nil {
                        action("Save Clip…", primary: true) { save() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        action("Generate", primary: true) { generate() }.disabled(job != nil || !isValid)
                    }
                }
            }
            .padding(8)
        }
        .onDisappear {
            job?.cancel()
            if let priorPlayback {
                workspace.refreshLibrary()
                workspace.preview.playsAnimation = priorPlayback.playing
                workspace.preview.seekGraph(to: priorPlayback.time)
            }
        }
        .keyboardShortcuts([KeyboardShortcutAction(.escape) { close() }])
        .accessibilityIdentifier("AdaEditor.Animator.Kimodo.Panel")
    }

    private var isValid: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.utf8.count <= 4096
            && Double(duration).map { (1...10).contains($0) } == true
    }

    private func field(_ title: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr(title)).font(.system(size: 12))
            TextField(L10n.tr(title), text: value).textFieldStyle(EditorAnimationFieldStyle(colors: theme.editorColors))
                .frame(height: 28)
                .disabled(job != nil)
        }
    }

    private func action(_ title: String, primary: Bool = false, _ body: @escaping () -> Void) -> some View {
        Button(action: body) { Text(L10n.tr(title)) }
            .buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors, selected: primary))
    }

    private func generate() {
        guard let seconds = Double(duration), let rig = workspace.preview.asset?.animationRig,
              let binding = workspace.sourceLibrary?.binding else {
            return
        }
        let description = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        error = ""
        let progress = self.progress
        progress.status = L10n.tr("Preparing Kimodo…")
        job = Task {
            defer { job = nil; progress.status = "" }
            do {
                try workspace.requireNoUnkeyedPose()
                try SOMAHumanoidMotion.validateTarget(rig)
                let motion = try await EditorKimodoRunner.shared.generate(prompt: description, duration: seconds) {
                    await MainActor.run { progress.status = L10n.tr("Generating movement…") }
                }
                try Task.checkCancellation()
                guard let current = workspace.preview.asset?.animationRig, binding.isCompatible(with: current) else { throw EditorKimodoError.invalidResult }
                let title = L10n.tr("Generated movement")
                let clip = try motion.clip(named: title, for: rig)
                var generated = AnimationLibrary(binding: binding)
                try generated.extract(clip, rig: rig)
                guard let id = generated.clips.first?.id else { throw EditorKimodoError.invalidResult }
                priorPlayback = (workspace.preview.playsAnimation, workspace.preview.playbackTime)
                try workspace.preview.installAnimationLibraries((workspace.library.map { [$0.library] } ?? []) + [generated])
                workspace.preview.animationGraph = nil
                workspace.preview.selectedAnimation = generated.runtimeName(for: id)
                workspace.preview.animationRepeats = true
                workspace.preview.playsAnimation = true
                draft = generated
                name = title
            } catch is CancellationError {
                return
            } catch SOMAHumanoidMotion.Failure.unsupportedJoint(let joint) {
                self.error = L10n.text("The selected humanoid has a missing or unsupported joint: \(joint).")
            } catch { self.error = L10n.tr(error.localizedDescription) }
        }
    }

    private func save() {
        guard let draft, var clip = draft.clips.first else {
            return
        }
        clip.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try workspace.saveGeneratedClip(clip, binding: draft.binding)
            priorPlayback = nil
            self.draft = nil
            close()
        } catch { self.error = L10n.tr(error.localizedDescription) }
    }
}

@Observable
@MainActor
private final class EditorKimodoProgress {
    var status = ""
}
#endif
