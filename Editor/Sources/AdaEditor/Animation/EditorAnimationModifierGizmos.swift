import AdaEngine
import Math

struct EditorAnimationModifierDrag {
    let document: EditorAnimationModifierDocument
    let revision: String
    let id: String
    let pole: Bool
    let planePoint: Vector3
    var candidate: AnimationPoseModifier
}

extension EditorAnimationAssetWorkspace {
    /// A handle drag previews freely, then commits one revision/history entry on release.
    func handleModifierInput(_ input: any InputEvent, camera: EditorModelPreviewCamera) -> Bool {
        if let key = input as? KeyEvent, key.keyCode == .escape, modifierDrag != nil { cancelModifierDrag(); return true }
        guard let mouse = input as? MouseEvent, mouse.button == .left else { return false }
        if mouse.phase == .began {
            guard timeline.inspectorMode == "modifiers", !timeline.hasUnkeyedPose,
                  let document = modifiers, let modifier = selectedModifier else { return false }
            let matrix = preview.normalizationTransform.matrix
            let targets: [(Bool, Vector3)] = [(false, modifier.target)] + (modifier.pole.map { [(true, $0)] } ?? [])
            for (isPole, point) in targets {
                let world = (matrix * Vector4(point, 1)).xyz
                if let screen = camera.project(world), (screen - Vector2(mouse.mousePosition.x, mouse.mousePosition.y)).squaredLength <= 144 {
                    modifierDrag = .init(document: document, revision: document.revision, id: modifier.id, pole: isPole, planePoint: world, candidate: modifier)
                    return true
                }
            }
            return false
        }
        guard var drag = modifierDrag else { return false }
        if mouse.phase == .cancelled { cancelModifierDrag(); return true }
        defer { if mouse.phase == .ended { modifierDrag = nil; refreshModifiers() } }
        do {
            guard modifiers === drag.document, selectedModifierID == drag.id else { cancelModifierDrag(); return true }
            try drag.document.checkRevision(drag.revision, editable: true)
            if let world = camera.unproject(mouse.mousePosition, atDepthOf: drag.planePoint) {
                let point = (preview.normalizationTransform.matrix.inverse * Vector4(world, 1)).xyz
                if drag.pole { drag.candidate.pole = point } else { drag.candidate.target = point }
                var stack = drag.document.stack
                try stack.apply([.init(kind: .update, modifierID: drag.id, modifier: drag.candidate)])
                try preview.installPoseModifiers(stack)
                modifierDrag = drag
                if mouse.phase == .ended {
                    modifierDrag = nil
                    try drag.document.commit(stack, expectedRevision: drag.revision)
                    refreshModifiers()
                }
            }
        } catch {
            modifierDrag = nil
            refreshModifiers()
            self.error = error.localizedDescription
        }
        return true
    }

    func cancelModifierDrag() { modifierDrag = nil; refreshModifiers() }
}

extension EditorModelAssetPreviewModel {
    /// Alternating anchor/handle pairs, already converted to the normalized viewport world.
    func modifierHandleSegments() -> [Vector3] {
        guard let player = capturedAnimationPlayer(), let modifier = player.poseModifiers.first(where: { $0.id == selectedPoseModifierID }),
              let first = modifier.joints.first, let last = modifier.joints.last,
              let end = modifierNodeIndex(last), let root = modifierNodeIndex(first),
              player.globalTransforms.indices.contains(end), player.globalTransforms.indices.contains(root) else { return [] }
        let matrix = normalizationTransform.matrix
        var points = [(matrix * Vector4(player.globalTransforms[end].origin, 1)).xyz, (matrix * Vector4(modifier.target, 1)).xyz]
        if let pole = modifier.pole {
            points.append((matrix * Vector4(player.globalTransforms[root].origin, 1)).xyz)
            points.append((matrix * Vector4(pole, 1)).xyz)
        }
        return points
    }
}
