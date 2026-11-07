import AdaEngine
import Foundation

extension EditorAnimationAssetWorkspace {
    func openModifiers() throws {
        guard let service else { throw failure() }
        try attachModifiers(service.openModifiers(modifierPath))
    }

    func createModifiers() throws {
        try requireNoUnkeyedPose()
        guard let service, let binding = sourceLibrary?.binding else { throw failure() }
        try attachModifiers(service.createModifiers(modifierPath, binding: binding))
    }

    private func attachModifiers(_ document: EditorAnimationModifierDocument) throws {
        if let rig = preview.asset?.animationRig, !document.stack.binding.isCompatible(with: rig) { throw AnimationPoseModifierError.incompatibleRig }
        modifiers = document
        selectedModifierID = document.stack.modifiers.first?.id
        timeline.inspectorMode = "modifiers"
        refreshModifiers()
    }

    func refreshModifiers() {
        do {
            if modifiers?.isDiscarded == true { modifiers = nil }
            if preview.asset != nil { try preview.installPoseModifiers(modifiers?.stack) }
        } catch { self.error = error.localizedDescription }
    }

    func editModifiers(_ operations: [AnimationModifierEdit]) throws {
        try requireNoUnkeyedPose()
        guard let document = modifiers else { throw failure() }
        var draft = document.stack
        try draft.apply(operations)
        try document.commit(draft, expectedRevision: document.revision)
        refreshModifiers()
    }

    var selectedModifier: AnimationPoseModifier? { modifiers?.stack.modifiers.first { $0.id == selectedModifierID } }

    /// Uses the hierarchy's authored order, requiring a contiguous selected chain.
    func addModifier(_ kind: AnimationPoseModifier.Kind) throws {
        guard let binding = modifiers?.stack.binding ?? sourceLibrary?.binding else { throw failure() }
        let ids = timeline.selectedNodes
        let nodes = binding.nodes
        var chain: [String] = []
        guard let root = nodes.first(where: { ids.contains($0.id) && ($0.parentID.map { !ids.contains($0) } ?? true) }) else { throw failure() }
        chain.append(root.id)
        while let child = nodes.first(where: { ids.contains($0.id) && $0.parentID == chain.last }), !chain.contains(child.id) { chain.append(child.id) }
        guard chain.count == ids.count, kind != .twoBone || chain.count == 3, chain.count >= 2 else { throw failure() }
        let end = chain.last.flatMap { id in nodes.firstIndex(where: { $0.id == id }) }
        let point = end.flatMap { preview.capturedAnimationPlayer()?.globalTransforms[$0].origin } ?? .zero
        let modifier = AnimationPoseModifier(kind: kind, joints: chain, target: point)
        var candidate = modifiers?.stack ?? AnimationModifierStack(binding: binding)
        try candidate.apply([.init(kind: .add, modifier: modifier)])
        if modifiers == nil { try createModifiers() }
        try editModifiers([.init(kind: .add, modifier: modifier)])
        selectedModifierID = modifier.id
        timeline.inspectorMode = "modifiers"
        revealInspector?()
    }

    private func failure() -> AnimationAuthoringError {
        .init(.invalidTrack, itemID: "modifiers", message: L10n.tr("Select a contiguous bone chain before adding IK."))
    }
}
