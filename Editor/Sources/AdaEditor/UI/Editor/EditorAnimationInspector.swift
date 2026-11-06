@_spi(AdaEngine) import AdaEngine
import Foundation
import Math

struct EditorAnimationInspector: View {
    let workspace: EditorAnimationAssetWorkspace
    private var model: EditorAnimationTimelineModel { workspace.timeline }
    @State private var keyTime = "0"
    @State private var keyValue = ""
    @State private var incoming = ""
    @State private var outgoing = ""
    @State private var keyRevision = ""
    @State private var poseDrafts: [String: [String]] = [:]
    @State private var editedComponents: [String: Set<Int>] = [:]
    @State private var eulerDegrees = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            adaEditorInspectorTitle(theme: theme)
            if model.inspectorMode == "modifiers" || workspace.document.kind == .animationModifiers && model.inspectorMode != "preview" && model.inspectorMode != "graph" {
                ScrollView(.vertical, showsIndicators: true) { EditorAnimationModifierInspector(workspace: workspace).padding(12) }
            } else if workspace.mode == .graph && model.inspectorMode == "graph" {
                Text(L10n.tr("Asset preview draft")).font(.system(size: 11)).padding(8)
                action("Save Preview Workspace") { model.perform { try workspace.saveWorkspaceState() } }
                EditorAnimationGraphEditor(model: workspace.graph, presentation: .inspector)
            } else if model.inspectorMode == "preview" {
                ScrollView(.vertical, showsIndicators: true) { previewSettings.padding(12) }
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(workspace.document.title).font(.system(size: 14, weight: .semibold))
                        libraryControls
                        if let node = model.selectedNode {
                            Text(node.name ?? node.id).font(.system(size: 12, weight: .semibold))
                            Text(node.id).font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
                            Text(nodePath(node.id)).font(.system(size: 10)).lineLimit(4).foregroundColor(theme.editorColors.muted)
                            Text(L10n.tr(nodeType(node.id))).font(.system(size: 10))
                            Text(L10n.tr("Selected bones") + ": \(model.selectedNodes.count)").font(.system(size: 11))
                            action("Select Subtree") { model.selectSubtree(node.id) }
                            if node.restTranslation != nil {
                                restPose(node)
                                poseControls
                            } else {
                                Text(L10n.tr("This node keeps its imported matrix transform.")).font(.system(size: 11))
                            }
                        }
                        if let track = model.selectedTrack {
                            Text(L10n.tr(track.channel.rawValue)).font(.system(size: 11, weight: .semibold))
                            EditorEnumField(cases: AnimationLibraryTrack.Interpolation.allCases.filter { track.channel != .rotation || $0 != .bezier }.map(\.rawValue),
                                selection: Binding(get: { track.interpolation.rawValue }, set: { value in
                                    model.perform {
                                        if let clip = model.clip, let interpolation = AnimationLibraryTrack.Interpolation(rawValue: value) {
                                            try model.apply([.init(kind: .configureTrack, clipID: clip.id, trackID: track.id, interpolation: interpolation)])
                                        }
                                    }
                                }), accessibilityID: "AdaEditor.Animation.Track.Interpolation")
                            EditorEnumField(cases: model.clip?.tracks.filter { model.selectedNodes.contains($0.nodeID) }.map(\.id) ?? [],
                                selection: Binding(get: { track.id }, set: { id in
                                    model.selectedTrackID = id; model.selectedKeys = []
                                    model.selectedChannel = model.clip?.tracks.first { $0.id == id }?.channel
                                }),
                                accessibilityID: "AdaEditor.Animation.Track", labels: trackLabels, localizesValues: false)
                            if model.selectedKeys.count > 1 {
                                Text(L10n.tr("Mixed values")).font(.system(size: 11))
                            } else if let ref = model.selectedKeys.first, ref.track == track.id, let key = track.keys.first(where: { $0.id == ref.key }) {
                                keyFields(track, key: key)
                            }
                        }
                        if !model.error.isEmpty { Text(model.error).font(.system(size: 11)).foregroundColor(.red) }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundColor(theme.editorColors.text).accessibilityIdentifier("AdaEditor.Animation.Inspector")
            .onChange(of: model.selectedKeys) { _, _ in synchronizeKey() }
            .onChange(of: model.selectedTrackID) { _, _ in synchronizeKey() }
            .onChange(of: workspace.library?.revision) { _, _ in synchronizeKey(); resetPoseDrafts() }
            .onChange(of: model.selectedNodes) { _, _ in resetPoseDrafts() }
            .onChange(of: model.timeText) { _, _ in resetPoseDrafts() }
            .onChange(of: model.clip?.id) { _, _ in resetPoseDrafts() }
            .onChange(of: workspace.library?.previewSerial) { _, _ in resetPoseDrafts() }
    }

    private var trackLabels: [String: String] {
        (model.clip?.tracks ?? []).reduce(into: [:]) { $0[$1.id] = L10n.tr($1.channel.rawValue) }
    }

    private func nodePath(_ id: String) -> String {
        let nodes = model.nodes.reduce(into: [String: AnimationRigBinding.Node]()) { $0[$1.id] = $1 }
        var current: String? = id, names: [String] = [], visited: Set<String> = []
        while let id = current, let node = nodes[id], visited.insert(id).inserted {
            names.append(node.name ?? node.id); current = node.parentID
        }
        return names.reversed().joined(separator: "/")
    }

    private func nodeType(_ id: String) -> String {
        guard let index = model.nodes.firstIndex(where: { $0.id == id }), let asset = workspace.preview.asset else { return "Node" }
        if asset.skins.contains(where: { $0.joints.contains(index) }) { return "Bone" }
        return asset.nodes.indices.contains(index) && asset.nodes[index].meshIndex != nil ? "Mesh" : "Node"
    }

    private func restPose(_ node: AnimationRigBinding.Node) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.tr("Rest pose")).font(.system(size: 11, weight: .semibold))
            if let value = node.restTranslation { restValues("translation", [value.x, value.y, value.z]) }
            if let value = node.restRotation { restValues("rotation", [value.x, value.y, value.z, value.w]) }
            if let value = node.restScale { restValues("scale", [value.x, value.y, value.z]) }
        }.accessibilityIdentifier("AdaEditor.Animation.Pose.Rest")
    }

    private func restValues(_ title: String, _ values: [Float]) -> some View {
        HStack {
            Text(L10n.tr(title)).font(.system(size: 10))
            Text(values.map { String(format: "%.4g", $0) }.joined(separator: ", ")).font(.system(size: 10))
        }.foregroundColor(theme.editorColors.muted)
    }

    private var previewSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("Preview Settings")).font(.system(size: 13, weight: .semibold))
            Text(workspace.document.title).font(.system(size: 11))
            EditorEnumField(cases: ["perspective", "orthographic"], selection: Binding(
                get: { workspace.camera.isOrthographic ? "orthographic" : "perspective" },
                set: { workspace.camera.isOrthographic = $0 == "orthographic" }), accessibilityID: "AdaEditor.Animation.Projection",
                labels: ["perspective": L10n.tr("Perspective"), "orthographic": L10n.tr("Orthographic")], localizesValues: false)
            Text(L10n.tr("Background")).font(.system(size: 11))
            EditorEnumField(cases: ["dark", "gray", "light"], selection: Binding(
                get: { workspace.camera.backgroundStyle }, set: { workspace.camera.backgroundStyle = $0 }), accessibilityID: "AdaEditor.Animation.Background",
                labels: ["dark": L10n.tr("Dark"), "gray": L10n.tr("Gray"), "light": L10n.tr("Light")], localizesValues: false)
            Text(L10n.tr("Lighting intensity")).font(.system(size: 11))
            Slider(value: Binding(get: { Double(workspace.camera.lightingIntensity) }, set: {
                if $0.isFinite { workspace.camera.lightingIntensity = Float(max(0, min(8, $0))) }
            }), in: 0...8).frame(maxWidth: .infinity).accessibilityIdentifier("AdaEditor.Animation.Lighting")
            Text(String(format: "%.2f", workspace.camera.lightingIntensity)).font(.system(size: 11))
            action(workspace.camera.showsGrid ? "Hide grid" : "Show grid", selected: workspace.camera.showsGrid) { workspace.camera.showsGrid.toggle() }
            action(workspace.camera.showsAxes ? "Hide axes" : "Show axes", selected: workspace.camera.showsAxes) { workspace.camera.showsAxes.toggle() }
            action(workspace.preview.showsBones ? "Hide bones" : "Show bones", selected: workspace.preview.showsBones) { workspace.preview.showsBones.toggle() }
            action("Frame model") { workspace.camera.reset() }
            action("Frame Selection") { workspace.camera.frameSelection(workspace.preview.selectedWorldPoints()) }
                .disabled(model.selectedNodes.isEmpty)
            action("Save Preview Workspace") { model.perform { try workspace.saveWorkspaceState() } }
        }.frame(maxWidth: .infinity, alignment: .topLeading).accessibilityIdentifier("AdaEditor.Animation.PreviewSettings")
    }

    private var poseControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("Local pose")).font(.system(size: 11, weight: .semibold))
            action(eulerDegrees ? "Euler degrees (Z, X, Y)" : "Quaternion XYZW") {
                model.perform {
                    let width = eulerDegrees ? 3 : 4
                    let values = (0..<width).compactMap { Float(poseBinding(.rotation, index: $0).wrappedValue) }
                    guard values.count == width, values.allSatisfy(\.isFinite) else { throw invalidNumbers() }
                    let converted: [Float]
                    if eulerDegrees {
                        let rotation = Quat.euler(Vector3(values[0], values[1], values[2]) * (Float.pi / 180)).normalized
                        converted = [rotation.x, rotation.y, rotation.z, rotation.w]
                    } else { converted = EditorAnimationTimelineModel.eulerDegrees(values) }
                    guard !converted.isEmpty else { throw invalidNumbers() }
                    if editedComponents["rotation"]?.isEmpty == false {
                        // Apply edited components in their original representation to each bone first.
                        try model.setPose(.rotation, values: values, components: editedComponents["rotation"], euler: eulerDegrees)
                    }
                    eulerDegrees.toggle()
                    poseDrafts["rotation"] = converted.map { String(format: "%.7g", $0) }
                    editedComponents["rotation"] = []
                }
            }.accessibilityIdentifier("AdaEditor.Animation.Pose.RotationMode")
            ForEach([AnimationLibraryTrack.Channel.translation, .rotation, .scale], id: \.rawValue) { channel in
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr(channel.rawValue)).font(.system(size: 10))
                    HStack(spacing: 4) {
                        ForEach(0..<(channel == .rotation && !eulerDegrees ? 4 : 3), id: \.self) { index in
                            EditorAnimationAxisField(axis: ["X", "Y", "Z", "W"][index], text: poseBinding(channel, index: index),
                                identifier: "AdaEditor.Animation.Pose.\(channel.rawValue).\(index)")
                        }
                    }.accessibilityIdentifier("AdaEditor.Animation.Pose.\(channel.rawValue)")
                    if (0..<(channel == .rotation && !eulerDegrees ? 4 : 3)).contains(where: { isMixed(channel, index: $0) }) {
                        Text(L10n.tr("Mixed values")).font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
                            .accessibilityIdentifier("AdaEditor.Animation.Pose.Mixed.\(channel.rawValue)")
                    }
                    action("Preview Pose", prominent: true) {
                        model.perform {
                            let width = channel == .rotation && !eulerDegrees ? 4 : 3
                            let values = (0..<width).compactMap { Float(poseBinding(channel, index: $0).wrappedValue) }
                            guard values.count == width, values.allSatisfy(\.isFinite) else { throw invalidNumbers() }
                            try model.setPose(channel, values: values, components: editedComponents[channel.rawValue] ?? [], euler: channel == .rotation && eulerDegrees)
                            poseDrafts[channel.rawValue] = nil
                            editedComponents[channel.rawValue] = nil
                        }
                    }.disabled(!model.isEditable || workspace.mode == .graph)
                        .accessibilityIdentifier("AdaEditor.Animation.Pose.Apply.\(channel.rawValue)")
                }
            }
        }
    }

    private func poseBinding(_ channel: AnimationLibraryTrack.Channel, index: Int) -> Binding<String> {
        func values() -> [String] {
            if let draft = poseDrafts[channel.rawValue] { return draft }
            let values = model.sampledValues(channel)
            return (channel == .rotation && eulerDegrees ? EditorAnimationTimelineModel.eulerDegrees(values) : values).map { String(format: "%.7g", $0) }
        }
        return Binding(get: { let data = values(); return data.indices.contains(index) ? data[index] : "0" }, set: { text in
            workspace.preview.playsAnimation = false
            var data = values()
            while data.count <= index { data.append("0") }
            data[index] = text
            poseDrafts[channel.rawValue] = data
            editedComponents[channel.rawValue, default: []].insert(index)
        })
    }

    private func resetPoseDrafts() { poseDrafts = [:]; editedComponents = [:] }

    private func isMixed(_ channel: AnimationLibraryTrack.Channel, index: Int) -> Bool {
        guard editedComponents[channel.rawValue]?.contains(index) != true else { return false }
        let values = model.selectedNodes.compactMap { id -> Float? in
            let sampled = model.sampledValues(channel, nodeID: id)
            let components = channel == .rotation && eulerDegrees ? EditorAnimationTimelineModel.eulerDegrees(sampled) : sampled
            return components.indices.contains(index) ? components[index] : nil
        }
        guard let first = values.first else { return false }
        return values.contains { abs($0 - first) > 0.000001 }
    }

    private var libraryControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let document = workspace.library {
                Text(document.relativePath).font(.system(size: 10)).lineLimit(3)
                if document.isDirty { Text(L10n.tr("Unsaved animation")).font(.system(size: 11)).foregroundColor(theme.editorColors.blue) }
                action("Save", prominent: true) { model.perform { try document.save(expectedRevision: document.revision) } }
                action("Reload from Disk") { recover(document, discard: false) }
                    .disabled(model.hasUnkeyedPose || workspace.isWorking).accessibilityIdentifier("AdaEditor.Animation.Library.Reload")
                action("Discard Local Edits and Reload") { recover(document, discard: true) }
                    .disabled(model.hasUnkeyedPose || workspace.isWorking).accessibilityIdentifier("AdaEditor.Animation.Library.DiscardReload")
                action("Discard Draft") {
                    model.perform {
                        try workspace.requireNoUnkeyedPose()
                        try workspace.service?.discard(document, expectedRevision: document.revision, discardChanges: true)
                        workspace.library = nil
                        workspace.mode = .clips
                        model.selectedKeys = []; model.selectedTrackID = nil; model.selectedChannel = nil
                        workspace.refreshLibrary()
                    }
                }.disabled(model.hasUnkeyedPose || workspace.isWorking).accessibilityIdentifier("AdaEditor.Animation.Library.Discard")
            }
            Text(L10n.tr(model.isEditable ? "Editable animation" : "Imported animation (read-only)")).font(.system(size: 11))
            Text(L10n.tr("Source asset")).font(.system(size: 10))
            Text(model.library?.binding.sourceAsset ?? workspace.document.relativePath).font(.system(size: 10)).lineLimit(3)
            if let clip = model.clip {
                Text(L10n.tr("Source clip")).font(.system(size: 10))
                Text(clip.sourceClip ?? clip.name).font(.system(size: 10))
            }
            field("Animation library path", text: Binding(get: { workspace.libraryPath }, set: { workspace.libraryPath = $0 }))
            field("Clip name", text: Binding(get: { workspace.clipName }, set: { workspace.clipName = $0 }))
            action("Extract Editable Copy") { workspace.run { try await workspace.extract(fromRest: false) } }
                .disabled(workspace.sourceClip.isEmpty || workspace.isWorking || model.hasUnkeyedPose)
            action("New Animation") { workspace.run { try await workspace.extract(fromRest: true) } }.disabled(workspace.isWorking || model.hasUnkeyedPose)
            action("Open Library") { workspace.run { try workspace.openLibrary() } }.disabled(model.hasUnkeyedPose)
            action("Insert Key", prominent: true) { model.perform { try model.insertKeys() } }.disabled(!model.isEditable || model.selectedNodes.isEmpty)
            action(model.autoKey ? "Auto Key: On" : "Auto Key: Off", selected: model.autoKey) {
                if model.hasUnkeyedPose { model.error = L10n.tr("Insert or discard the unkeyed pose first.") }
                else { model.autoKey.toggle() }
            }
        }
    }

    private func recover(_ document: EditorAnimationLibraryDocument, discard: Bool) {
        model.perform {
            try workspace.requireNoUnkeyedPose()
            try workspace.service?.reload(document, expectedRevision: document.revision, discardChanges: discard)
            model.selectedKeys = []; model.selectedTrackID = nil; model.selectedChannel = nil
            workspace.refreshLibrary()
        }
    }

    private func keyFields(_ track: AnimationLibraryTrack, key: AnimationLibraryKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            field("Seconds", text: $keyTime).accessibilityIdentifier("AdaEditor.Animation.Key.Time")
            field("Key values, separated by commas", text: $keyValue).accessibilityIdentifier("AdaEditor.Animation.Key.Value")
            if track.interpolation == .cubicSpline {
                field("Incoming derivative", text: $incoming)
                field("Outgoing derivative", text: $outgoing)
            }
            action("Update Key") {
                model.perform {
                    guard let clip = model.clip, let time = Double(keyTime), let values = numbers(keyValue) else { throw invalidNumbers() }
                    var edited = key
                    edited.time = time; edited.value = values
                    if track.interpolation == .cubicSpline { edited.incoming = numbers(incoming); edited.outgoing = numbers(outgoing) }
                    try model.apply([.init(kind: .putKey, clipID: clip.id, trackID: track.id, key: edited, replaceExisting: true)], revision: keyRevision)
                }
            }.disabled(!model.isEditable).accessibilityIdentifier("AdaEditor.Animation.Key.Update")
            action("Delete Key") { model.perform { try model.deleteKeys() } }.disabled(!model.isEditable)
            EditorAnimationCurveInspector(model: model, track: track, key: key)
        }.onAppear { synchronizeKey() }
    }

    private func synchronizeKey() {
        guard let reference = model.selectedKeys.first, let track = model.clip?.tracks.first(where: { $0.id == reference.track }),
              let key = track.keys.first(where: { $0.id == reference.key }) else { return }
        keyTime = String(key.time)
        keyRevision = workspace.library?.revision ?? ""
        keyValue = key.value.map(String.init(describing:)).joined(separator: ", ")
        incoming = key.incoming?.map(String.init(describing:)).joined(separator: ", ") ?? ""
        outgoing = key.outgoing?.map(String.init(describing:)).joined(separator: ", ") ?? ""
    }

    private func numbers(_ text: String) -> [Float]? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        let values = parts.compactMap { Float($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return values.count == parts.count && values.allSatisfy(\.isFinite) ? values : nil
    }

    private func invalidNumbers() -> AnimationAuthoringError {
        .init(.invalidKey, itemID: "input", message: L10n.tr("Enter finite numeric values for every component."))
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.tr(title)).font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
            TextField(L10n.tr(title), text: text).textFieldStyle(EditorAnimationFieldStyle(colors: theme.editorColors))
                .frame(maxWidth: .infinity)
        }
    }
    private func action(_ title: String, prominent: Bool = false, selected: Bool = false, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Text(L10n.tr(title)).font(.system(size: 11)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors, prominent: prominent, selected: selected))
    }
}
