import AdaEngine
import Foundation
import Math

struct EditorAnimationModifierInspector: View {
    let workspace: EditorAnimationAssetWorkspace
    @State private var name = ""
    @State private var rootBone = ""
    @State private var endBone = ""
    @State private var influence = "1"
    @State private var iterations = "16"
    @State private var tolerance = ""
    @State private var target: [String] = ["0", "0", "0"]
    @State private var pole: [String] = ["0", "1", "0"]
    @State private var usesPole = false
    @State private var sceneTarget = ""
    @State private var sceneDraft: EditorIKSceneBindingDraft = EditorIKSceneBindingDraft()
    @Environment(\.theme) private var theme
    private var document: EditorAnimationModifierDocument? { workspace.modifiers }
    private var modifier: AnimationPoseModifier? { workspace.selectedModifier }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("Modifiers")).font(.system(size: 14, weight: .semibold))
            resourceControls
            if let modifier {
                constraintControls(modifier)
                sceneControls
                diagnostics
            } else { Text(L10n.tr("Select a contiguous bone chain before adding IK.")).font(.system(size: 11)) }
            if !workspace.error.isEmpty { Text(workspace.error).font(.system(size: 11)).foregroundColor(.red) }
            if !workspace.timeline.error.isEmpty { Text(workspace.timeline.error).font(.system(size: 11)).foregroundColor(.red) }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
            .onAppear { synchronize(); synchronizeSceneBinding() }
            .onChange(of: workspace.selectedModifierID) { _, _ in synchronize(); synchronizeSceneBinding() }
            .onChange(of: document?.revision) { _, _ in synchronize() }
            .onChange(of: sceneTarget) { _, _ in synchronizeSceneBinding() }
            .accessibilityIdentifier("AdaEditor.Animation.Modifier.Inspector")
    }

    private var resourceControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(L10n.tr("Modifier resource path"), text: Binding(get: { workspace.modifierPath }, set: { workspace.modifierPath = $0 }))
                .textFieldStyle(EditorAnimationFieldStyle(colors: theme.editorColors))
            VStack(alignment: .leading, spacing: 4) {
                action("Open IK Resource") { try workspace.openModifiers() }
                action("Create IK Resource") { try workspace.createModifiers() }.disabled(document != nil || workspace.sourceLibrary == nil)
            }
            if let document {
                Text(document.relativePath).font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
                if document.isDirty { Text(L10n.tr("Unsaved animation")).font(.system(size: 11)).foregroundColor(theme.editorColors.blue) }
                HStack(spacing: 4) {
                    action("Save", primary: true) { try document.save(expectedRevision: document.revision) }
                    action("Undo") { try document.undo(expectedRevision: document.revision) }.disabled(!document.canUndo)
                    action("Redo") { try document.redo(expectedRevision: document.revision) }.disabled(!document.canRedo)
                }
            }
        }
    }

    private func constraintControls(_ modifier: AnimationPoseModifier) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L10n.tr("Name"), text: $name).textFieldStyle(EditorAnimationFieldStyle(colors: theme.editorColors))
            action(modifier.enabled ? "IK Enabled" : "IK Disabled", selected: modifier.enabled) {
                var value = modifier; value.enabled.toggle()
                try workspace.editModifiers([.init(kind: .update, modifierID: value.id, modifier: value)])
            }
            bonePicker("Root bone", selection: $rootBone)
            bonePicker("End bone", selection: $endBone)
            Text(L10n.tr("IK Target (model space)")).font(.system(size: 11, weight: .semibold))
            vectorFields($target, identifier: "Target")
            if modifier.kind == .twoBone {
                action("Pole", selected: usesPole) { usesPole.toggle() }
                if usesPole { vectorFields($pole, identifier: "Pole") }
            }
            field("Influence", value: $influence)
            if modifier.kind == .fabrik {
                field("Iterations", value: $iterations)
                field("Tolerance (empty = automatic)", value: $tolerance)
            }
            action("Apply IK", primary: true) { try apply(modifier) }
            HStack(spacing: 4) {
                action("Move Up") { try move(modifier, delta: -1) }
                action("Move Down") { try move(modifier, delta: 1) }
                action("Remove") { try workspace.editModifiers([.init(kind: .remove, modifierID: modifier.id)]); workspace.selectedModifierID = nil }
            }
        }
    }

    private func bonePicker(_ title: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.tr(title)).font(.system(size: 11))
            EditorEnumField(cases: document?.stack.binding.nodes.map(\.id) ?? [], selection: selection,
                            accessibilityID: "AdaEditor.Animation.Modifier.\(title)",
                            labels: (document?.stack.binding.nodes ?? []).reduce(into: [:]) { $0[$1.id] = ($1.name ?? $1.id) + " (\($1.id))" }, localizesValues: false)
        }
    }

    private var sceneCandidates: [(id: String, label: String, scene: EditorSceneDocument, entity: String)] {
        (workspace.workbench?.openDocuments ?? []).flatMap { document -> [(String, String, EditorSceneDocument, String)] in
            guard case let .scene(scene) = document, !scene.isReadOnly else { return [] }
            return (scene.sceneModel?.entities ?? []).filter { $0.components[EditorBuiltInComponentType.model3DSource] != nil }.map {
                (scene.id + "|" + $0.id, scene.title + " / " + $0.name, scene, $0.id)
            }
        }
    }

    private var sceneControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.tr("Scene target bindings")).font(.system(size: 12, weight: .semibold))
            EditorEnumField(cases: [""] + sceneCandidates.map(\.id), selection: $sceneTarget,
                            accessibilityID: "AdaEditor.Animation.Modifier.Scene",
                            labels: sceneCandidates.reduce(into: ["": L10n.tr("Choose scene model")]) { $0[$1.id] = $1.label }, localizesValues: false)
            TextField(L10n.tr("Target entity ID (empty = model point)"), text: sceneValue(\.targetEntity))
                .textFieldStyle(EditorAnimationFieldStyle(colors: theme.editorColors))
                .accessibilityIdentifier("AdaEditor.Animation.Modifier.SceneTarget")
            if sceneDraft.targetEntity.isEmpty {
                action("Override Target Point", selected: sceneDraft.targetUsesModelPoint) { sceneDraft.targetUsesModelPoint.toggle() }
            }
            if !sceneDraft.targetEntity.isEmpty || sceneDraft.targetUsesModelPoint { vectorFields(sceneValue(\.targetOffset), identifier: "TargetOffset") }
            TextField(L10n.tr("Pole entity ID (empty = model point)"), text: sceneValue(\.poleEntity))
                .textFieldStyle(EditorAnimationFieldStyle(colors: theme.editorColors))
                .accessibilityIdentifier("AdaEditor.Animation.Modifier.ScenePole")
            if sceneDraft.poleEntity.isEmpty {
                action("Override Pole Point", selected: sceneDraft.poleUsesModelPoint) { sceneDraft.poleUsesModelPoint.toggle() }
            }
            if !sceneDraft.poleEntity.isEmpty || sceneDraft.poleUsesModelPoint { vectorFields(sceneValue(\.poleOffset), identifier: "PoleOffset") }
            Text(L10n.tr("Marker offsets use local space. Asset preview uses model-space points.")).font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
            action("Reload Scene Bindings") { synchronizeSceneBinding() }.disabled(sceneTarget.isEmpty)
            if let selected = sceneCandidates.first(where: { $0.id == sceneTarget }),
               sceneDraft.sceneRevision != EditorAgentSceneToolService.revision(for: selected.scene.content) {
                Text(L10n.tr("Scene changed. Reload bindings before applying.")).font(.system(size: 11)).foregroundColor(theme.editorColors.blue)
            }
            Button(L10n.tr("Bind IK to Scene")) { workspace.run { try await bindScene() } }
                .buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors, selected: true))
                .disabled(document?.isDirty != false || sceneTarget.isEmpty)
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(workspace.preview.modifierDiagnostics.filter { $0.id == modifier?.id }, id: \.id) { result in
                Text(L10n.tr("IK status") + ": " + L10n.tr(result.status.rawValue)).font(.system(size: 11))
                if let error = result.reachError { Text(L10n.tr("Reach error") + ": \(error)").font(.system(size: 11)) }
                Text(L10n.tr("Iterations") + ": \(result.iterations)").font(.system(size: 11))
            }
        }.foregroundColor(theme.editorColors.muted)
    }

    private func field(_ title: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.tr(title)).font(.system(size: 11))
            TextField(L10n.tr(title), text: value).textFieldStyle(EditorAnimationFieldStyle(colors: theme.editorColors))
        }
    }

    private func vectorFields(_ values: Binding<[String]>, identifier: String) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                EditorAnimationAxisField(axis: ["X", "Y", "Z"][index], text: Binding(get: { values.wrappedValue[index] },
                    set: { values.wrappedValue[index] = $0 }), identifier: "AdaEditor.Animation.Modifier.\(identifier).\(index)")
            }
        }
    }

    private func action(_ title: String, primary: Bool = false, selected: Bool = false, perform: @escaping () throws -> Void) -> some View {
        Button { workspace.timeline.perform(perform) } label: { Text(L10n.tr(title)).font(.system(size: 11)).lineLimit(2) }
            .buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors, selected: primary || selected))
    }

    private func synchronize() {
        guard let modifier else { return }
        name = modifier.name ?? L10n.tr(modifier.kind == .twoBone ? "Two-bone IK" : "FABRIK")
        rootBone = modifier.joints.first ?? ""; endBone = modifier.joints.last ?? ""
        influence = String(modifier.influence); iterations = String(modifier.iterations)
        tolerance = modifier.tolerance.map { String($0) } ?? ""
        target = [modifier.target.x, modifier.target.y, modifier.target.z].map { String($0) }
        pole = modifier.pole.map { [$0.x, $0.y, $0.z].map { String($0) } } ?? ["0", "1", "0"]
        usesPole = modifier.pole != nil
    }

    private func vector(_ values: [String]) throws -> Vector3 {
        let parsed = values.compactMap(Float.init)
        guard parsed.count == 3, parsed.allSatisfy(\.isFinite) else { throw AnimationPoseModifierError.invalidModifier("point") }
        return Vector3(parsed[0], parsed[1], parsed[2])
    }

    private func apply(_ current: AnimationPoseModifier) throws {
        guard let nodes = document?.stack.binding.nodes, let influence = Float(influence), let iterations = Int(iterations) else {
            throw AnimationPoseModifierError.invalidModifier(current.id)
        }
        var path: [String] = [], next: String? = endBone
        while let id = next, !path.contains(id), path.count <= 65 {
            path.append(id)
            if id == rootBone { break }
            next = nodes.first { $0.id == id }?.parentID
        }
        guard path.last == rootBone else { throw AnimationPoseModifierError.invalidChain(current.id) }
        var value = current
        value.name = name; value.joints = Array(path.reversed()); value.influence = influence; value.iterations = iterations
        value.target = try vector(target); value.pole = usesPole ? try vector(pole) : nil
        value.tolerance = tolerance.isEmpty ? nil : Float(tolerance)
        guard tolerance.isEmpty || value.tolerance != nil else { throw AnimationPoseModifierError.invalidModifier(value.id) }
        try workspace.editModifiers([.init(kind: .update, modifierID: value.id, modifier: value)])
    }

    private func move(_ modifier: AnimationPoseModifier, delta: Int) throws {
        guard let values = document?.stack.modifiers, let index = values.firstIndex(where: { $0.id == modifier.id }), values.indices.contains(index + delta) else { return }
        try workspace.editModifiers([.init(kind: .move, modifierID: modifier.id, index: index + delta)])
    }

    private func bindScene() async throws {
        guard let document, let modifier, let workbench = workspace.workbench, let service = workspace.service,
              let candidate = sceneCandidates.first(where: { $0.id == sceneTarget }) else { return }
        let payload = candidate.scene.sceneModel?.entities.first { $0.id == candidate.entity }?.components[EditorBuiltInComponentType.model3DSource]
        var bindings: [String: AnimationIKBinding3D] = [:]
        if let value = payload?["modifierBindings"], value != .null {
            bindings = try JSONDecoder().decode([String: AnimationIKBinding3D].self, from: JSONEncoder().encode(value))
        }
        bindings[modifier.id] = try sceneDraft.binding()
        _ = try await service.execute(.init(action: .modifierBind, path: document.relativePath, expectedRevision: document.revision,
            scenePath: candidate.scene.relativePath, entityID: candidate.entity,
            sceneRevision: sceneDraft.sceneRevision, modifierBindings: bindings), workbench: workbench)
        synchronizeSceneBinding()
    }

    private func sceneValue<Value>(_ path: ReferenceWritableKeyPath<EditorIKSceneBindingDraft, Value>) -> Binding<Value> {
        Binding(get: { sceneDraft[keyPath: path] }, set: { sceneDraft[keyPath: path] = $0 })
    }

    private func synchronizeSceneBinding() {
        sceneDraft.load(nil, sceneRevision: "")
        guard let modifier, let selected = sceneCandidates.first(where: { $0.id == sceneTarget }),
              let payload = selected.scene.sceneModel?.entities.first(where: { $0.id == selected.entity })?.components[EditorBuiltInComponentType.model3DSource] else { return }
        do {
            let bindings = try payload["modifierBindings"].flatMap { value -> [String: AnimationIKBinding3D]? in
                if value == .null { return nil }
                return try JSONDecoder().decode([String: AnimationIKBinding3D].self, from: JSONEncoder().encode(value))
            } ?? [:]
            sceneDraft.load(bindings[modifier.id], sceneRevision: EditorAgentSceneToolService.revision(for: selected.scene.content))
        } catch { workspace.error = error.localizedDescription }
    }
}
