@_spi(AdaEngine) import AdaEngine
import Foundation
import Math

struct EditorAnimationLibraryAssetEditor: View {
    let document: EditorAssetDocument
    let workbench: EditorWorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(document.title).font(.system(size: 14, weight: .bold))
            EditorAnimationAssetViewport(workspace: workbench.animationWorkspace(for: document))
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The same document and command path is used by the scene Animator and an opened library asset.
struct EditorAnimationLibraryEditor: View {
    let document: EditorAnimationLibraryDocument
    let service: EditorAnimationAuthoringService
    @State private var preview: EditorModelAssetPreviewModel
    let showsPreview: Bool
    @State private var camera = EditorModelPreviewCamera()
    @State private var nodeID = ""
    @State private var trackID = ""
    @State private var keyID = ""
    @State private var keyTime = "0"
    @State private var keyValue = "0, 0, 0"
    @State private var incoming = ""
    @State private var outgoing = ""
    @State private var duration = "1"
    @State private var newName = ""
    @State private var channel = AnimationLibraryTrack.Channel.rotation
    @State private var eulerDegrees = false
    @State private var error = ""
    @Environment(\.theme) private var theme

    init(document: EditorAnimationLibraryDocument, service: EditorAnimationAuthoringService,
         preview: EditorModelAssetPreviewModel? = nil, showsPreview: Bool = true) {
        self.document = document
        self.service = service
        self._preview = State(wrappedValue: preview ?? EditorModelAssetPreviewModel())
        self.showsPreview = showsPreview
    }

    private var clip: AnimationLibraryClip? { document.library.clips.first { $0.id == document.selectedClipID } ?? document.library.clips.first }
    private var node: AnimationRigBinding.Node? { document.library.binding.nodes.first { $0.id == nodeID } ?? document.library.binding.nodes.first }
    private var track: AnimationLibraryTrack? {
        clip?.tracks.first { $0.id == trackID } ?? clip?.tracks.first { $0.nodeID == node?.id }
    }

    var body: some View {
        if document.isDiscarded { Text(L10n.text("Draft discarded. Open the library again.")) }
        else {
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: true) {
                    editorContent.frame(width: max(760, geometry.size.width), height: geometry.size.height)
                }
            }
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(document.relativePath).font(.system(size: 11))
                    if document.isDirty { Text(L10n.text("Unsaved animation")).font(.system(size: 11)) }
                    Spacer()
                    action("Save") { try document.save(expectedRevision: document.revision) }
                    action("Undo") { try document.undo(expectedRevision: document.revision) }.disabled(!document.canUndo)
                    action("Redo") { try document.redo(expectedRevision: document.revision) }.disabled(!document.canRedo)
                }
                HStack {
                    action("Reload from Disk") { try service.reload(document, expectedRevision: document.revision) }
                    action("Discard Local Edits and Reload") { try service.reload(document, expectedRevision: document.revision, discardChanges: true) }
                    action("Discard Draft") { try service.discard(document, expectedRevision: document.revision, discardChanges: true) }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                if showsPreview {
                VStack {
                    if preview.asset != nil { EditorModelPreviewViewport(model: preview, camera: camera).frame(minHeight: 150, maxHeight: .infinity) }
                    else { Text(preview.error ?? L10n.tr("Loading animation model…")) }
                    HStack {
                        action(preview.playsAnimation ? "Pause" : "Play", selected: preview.playsAnimation) { preview.playsAnimation.toggle() }
                        action("Seek") {
                            guard let time = Double(keyTime), time.isFinite else { throw inputError() }
                            preview.playsAnimation = false
                            preview.seekGraph(to: time)
                        }
                    }
                }.frame(width: 210)
                }
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("Clips")).font(.system(size: 11, weight: .semibold))
                        ForEach(document.library.clips, id: \.id) { value in
                            Button { selectClip(value) } label: {
                                Text(value.name).font(.system(size: 11)).foregroundColor(value.id == clip?.id ? theme.editorColors.blue : theme.editorColors.text)
                            }
                            .accessibilityIdentifier("AdaEditor.AnimationLibrary.Clip.\(value.id)")
                        }
                        field(L10n.text("Clip name"), text: $newName).frame(height: 28)
                        action("Create Clip") { try addPose(capture: false) }
                        action("Capture Pose") { try addPose(capture: true) }.disabled(preview.capturedAnimationPlayer() == nil)
                        Text(L10n.text("Bones")).font(.system(size: 11, weight: .semibold))
                        ForEach(document.library.binding.nodes, id: \.id) { value in
                            Button {
                                nodeID = value.id; trackID = ""; keyID = ""
                                synchronizeSelection(seek: true)
                            } label: {
                                Text("\(value.name ?? value.id) [\(value.id)]").font(.system(size: 10))
                                    .foregroundColor(value.id == node?.id ? theme.editorColors.blue : theme.editorColors.text)
                            }
                            .accessibilityIdentifier("AdaEditor.AnimationLibrary.Node.\(value.id)")
                        }
                    }
                }.frame(width: 150).frame(maxHeight: .infinity, alignment: .topLeading)
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 5) {
                        if let clip {
                            Text(clip.name).font(.system(size: 12, weight: .semibold))
                            HStack {
                                field(L10n.text("Duration"), text: $duration).frame(width: 65, height: 28)
                                action("Set Duration") {
                                    guard let value = Double(duration) else { throw inputError() }
                                    try edit(.init(kind: .configureClip, clipID: clip.id, duration: value))
                                }
                                action(clip.repeats ? "Loop: On" : "Loop: Off", selected: clip.repeats) {
                                    try edit(.init(kind: .configureClip, clipID: clip.id, repeats: !clip.repeats))
                                }
                            }
                            if let node {
                                Text("\(node.name ?? node.id) [\(node.id)]").font(.system(size: 11, weight: .semibold))
                                HStack {
                                    action(channel.rawValue) {
                                        let choices = AnimationLibraryTrack.Channel.allCases
                                        channel = choices[((choices.firstIndex(of: channel) ?? 0) + 1) % choices.count]
                                    }
                                    action("Add Bone Track") {
                                        let value = AnimationLibraryTrack(nodeID: node.id, channel: channel)
                                        try edit(.init(kind: .createTrack, clipID: clip.id, track: value))
                                        selectTrack(value)
                                    }
                                }
                                ForEach(clip.tracks.filter { $0.nodeID == node.id }, id: \.id) { value in
                                    Button { selectTrack(value) } label: {
                                        Text(L10n.tr(value.channel.rawValue)).font(.system(size: 11))
                                            .foregroundColor(value.id == track?.id ? theme.editorColors.blue : theme.editorColors.text)
                                    }
                                    .accessibilityIdentifier("AdaEditor.AnimationLibrary.Track.\(value.id)")
                                }
                            }
                            if let track {
                                timeline(track, duration: clip.duration).frame(height: 30)
                                HStack {
                                    field(L10n.text("Seconds"), text: $keyTime).frame(width: 70, height: 28)
                                        .accessibilityIdentifier("AdaEditor.AnimationLibrary.KeyTime")
                                    if track.channel == .rotation {
                                        action(eulerDegrees ? "Euler degrees (Z, X, Y)" : "Quaternion XYZW") {
                                            eulerDegrees.toggle(); keyValue = eulerDegrees ? "0, 0, 0" : "0, 0, 0, 1"
                                        }
                                    }
                                }
                                field(L10n.text("Key values, separated by commas"), text: $keyValue).frame(height: 28)
                                    .accessibilityIdentifier("AdaEditor.AnimationLibrary.KeyValue")
                                if track.interpolation == .cubicSpline {
                                    field(L10n.text("Incoming derivative"), text: $incoming).frame(height: 28)
                                    field(L10n.text("Outgoing derivative"), text: $outgoing).frame(height: 28)
                                }
                                HStack {
                                    action("Insert Key") { try putKey(replace: false) }
                                    action("Update Key") { try putKey(replace: true) }.disabled(keyID.isEmpty)
                                    action("Delete Key") { try edit(.init(kind: .removeKey, clipID: clip.id, trackID: track.id, keyID: keyID)); keyID = "" }
                                        .disabled(keyID.isEmpty)
                                    action(track.interpolation.rawValue) {
                                        let choices: [AnimationLibraryTrack.Interpolation] = [.linear, .step]
                                        let value = track.interpolation == .linear ? choices[1] : choices[0]
                                        try edit(.init(kind: .configureTrack, clipID: clip.id, trackID: track.id, interpolation: value))
                                    }
                                }
                                ForEach(track.keys, id: \.id) { key in
                                    Button { selectKey(key) } label: { Text("\(key.time) · \(key.value.map(String.init(describing:)).joined(separator: ", "))").font(.system(size: 10)) }
                                }
                            }
                        }
                        if !error.isEmpty { Text(error).font(.system(size: 11)).foregroundColor(.red) }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if showsPreview {
                preview.showsBones = true
                preview.playsAnimation = false
                do { preview.load(path: try service.resolve(document.library.binding.sourceAsset, extensions: ["glb", "gltf"]).path, resourceRoot: service.assetsURL) }
                catch { self.error = L10n.text("Animation edit failed: \(error.localizedDescription)") }
            }
            if let clip { selectClip(clip) }
        }
        .onDisappear { if showsPreview { preview.cancel() } }
        .onChange(of: preview.asset.map(ObjectIdentifier.init)) { _, _ in
            refreshPreview()
            if document.previewSerial > 0 { preview.playsAnimation = false; preview.seekGraph(to: document.previewTime) }
        }
        .onChange(of: document.revision) { _, _ in refreshPreview(); synchronizeSelection() }
        .onChange(of: document.previewSerial) { _, _ in refreshPreview(); preview.playsAnimation = false; preview.seekGraph(to: document.previewTime) }
        .onChange(of: document.selectedClipID) { _, _ in
            refreshPreview()
            synchronizeSelection()
        }
        .accessibilityIdentifier("AdaEditor.AnimationLibrary.Editor")
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(EditorAnimationFieldStyle(colors: theme.editorColors, height: 28))
    }

    private func action(_ title: String, selected: Bool = false, _ perform: @escaping () throws -> Void) -> some View {
        Button {
            do { try perform(); error = "" } catch { self.error = L10n.text("Animation edit failed: \(error.localizedDescription)") }
        } label: { Text(L10n.tr(title)).font(.system(size: 11)) }
            .buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors, selected: selected))
            .accessibilityIdentifier("AdaEditor.AnimationLibrary.Action.\(title)")
    }

    private func selectClip(_ value: AnimationLibraryClip) {
        document.selectedClipID = value.id; trackID = ""; keyID = ""; duration = String(format: "%.5g", value.duration)
        if nodeID.isEmpty { nodeID = value.tracks.first?.nodeID ?? document.library.binding.nodes.first?.id ?? "" }
        refreshPreview()
        synchronizeSelection()
    }

    /// Refresh field drafts after edits from any client, without overriding an explicit API preview seek.
    private func synchronizeSelection(seek: Bool = false) {
        guard let clip else { trackID = ""; keyID = ""; return }
        duration = String(format: "%.5g", clip.duration)
        if let selected = clip.tracks.first(where: { $0.id == trackID && $0.nodeID == node?.id }) {
            if let key = selected.keys.first(where: { $0.id == keyID }) { selectKey(key, seek: seek) }
            else { selectTrack(selected, seek: seek) }
        } else if let first = clip.tracks.first(where: { $0.nodeID == node?.id && $0.channel == .rotation })
            ?? clip.tracks.first(where: { $0.nodeID == node?.id }) {
            selectTrack(first, seek: seek)
        } else { trackID = ""; keyID = "" }
    }

    private func selectKey(_ value: AnimationLibraryKey, seek: Bool = true) {
        keyID = value.id; keyTime = String(value.time); eulerDegrees = false
        keyValue = value.value.map(String.init(describing:)).joined(separator: ", ")
        incoming = value.incoming?.map(String.init(describing:)).joined(separator: ", ") ?? ""
        outgoing = value.outgoing?.map(String.init(describing:)).joined(separator: ", ") ?? ""
        if seek { preview.playsAnimation = false; preview.seekGraph(to: value.time) }
    }

    private func selectTrack(_ value: AnimationLibraryTrack, seek: Bool = true) {
        trackID = value.id; keyID = ""; eulerDegrees = false
        if let first = value.keys.first { selectKey(first, seek: seek); return }
        keyTime = "0"; incoming = ""; outgoing = ""
        switch value.channel {
        case .translation: keyValue = "0, 0, 0"
        case .rotation: keyValue = "0, 0, 0, 1"
        case .scale: keyValue = "1, 1, 1"
        case .weights: keyValue = (node?.morphRestWeights ?? []).map(String.init(describing:)).joined(separator: ", ")
        }
    }

    private func edit(_ operation: AnimationEdit) throws {
        _ = try service.apply(path: document.relativePath, expectedRevision: document.revision, operations: [operation])
    }

    private func putKey(replace: Bool) throws {
        guard let clip, let track, let time = Double(keyTime), !replace || !keyID.isEmpty else { throw inputError() }
        var values = try numbers(keyValue)
        if track.channel == .rotation, eulerDegrees {
            guard values.count == 3 else { throw inputError() }
            let rotation = Quat.euler(Vector3(values[0], values[1], values[2]) * (Float.pi / 180)).normalized
            values = [rotation.x, rotation.y, rotation.z, rotation.w]
        }
        let cubic = track.interpolation == .cubicSpline
        let zero = Array(repeating: Float(0), count: values.count)
        let key = AnimationLibraryKey(id: replace ? keyID : UUID().uuidString, time: time, value: values,
            incoming: cubic ? (incoming.isEmpty ? zero : try numbers(incoming)) : nil,
            outgoing: cubic ? (outgoing.isEmpty ? zero : try numbers(outgoing)) : nil)
        try edit(.init(kind: .putKey, clipID: clip.id, trackID: track.id, key: key, replaceExisting: replace))
        selectKey(key)
    }

    private func addPose(capture: Bool) throws {
        let name = newName.isEmpty ? "Animation \(document.library.clips.count + 1)" : newName
        let value = try document.library.poseClip(name: name, duration: 1, from: capture ? preview.capturedAnimationPlayer() : nil)
        try edit(.init(kind: .createClip, clip: value))
        selectClip(value)
    }

    private func numbers(_ value: String) throws -> [Float] {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Float($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard numbers.count == parts.count, numbers.allSatisfy(\.isFinite) else { throw inputError() }
        return numbers
    }

    private func inputError() -> AnimationAuthoringError {
        .init(.invalidKey, itemID: keyID, message: "Enter finite numeric values with the channel's expected number of components.")
    }

    private func refreshPreview() {
        guard preview.asset != nil, let clip else { return }
        do {
            try preview.installAnimationLibraries([document.library])
            preview.animationGraph = nil
            preview.animationRepeats = clip.repeats
            preview.selectedAnimation = document.library.runtimeName(for: clip.id)
        } catch { self.error = L10n.text("Animation edit failed: \(error.localizedDescription)") }
    }

    private func timeline(_ track: AnimationLibraryTrack, duration: Double) -> some View {
        GeometryReader { geometry in
            ZStack(anchor: .topLeading) {
                RectangleShape().fill(theme.editorColors.muted.opacity(0.4)).frame(height: 1).offset(y: 12)
                ForEach(track.keys, id: \.id) { key in
                    Button { selectKey(key) } label: { Text("◆").foregroundColor(key.id == keyID ? .yellow : theme.editorColors.blue) }
                        .offset(x: Float(duration > 0 ? key.time / duration : 0) * max(0, geometry.size.width - 15), y: 3)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }
}
