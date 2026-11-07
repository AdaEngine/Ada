@_spi(AdaEngine) import AdaEngine
import Math

extension EditorModelAssetPreviewModel {
    func handleBoneSelection(_ input: any InputEvent, camera: EditorModelPreviewCamera) {
        guard let event = input as? MouseEvent, event.button == .left else { return }
        switch event.phase {
        case .began: bonePress = event.mousePosition; boneMoved = false
        case .changed:
            if let origin = bonePress, (event.mousePosition - origin).squaredLength > 16 { boneMoved = true }
        case .cancelled: bonePress = nil
        case .ended:
            defer { bonePress = nil }
            guard bonePress != nil, !boneMoved, showsBones,
                  let asset, let player = capturedAnimationPlayer() else { return }
            var closest: (Int, Float)?
            let joints = Set(asset.skins.flatMap(\.joints))
            for joint in joints where player.globalTransforms.indices.contains(joint) {
                let position = (normalizationTransform.matrix * player.globalTransforms[joint] * Vector4(0, 0, 0, 1)).xyz
                guard let screen = camera.project(position) else { continue }
                let distance = (screen - Vector2(event.mousePosition.x, event.mousePosition.y)).squaredLength
                if distance < 100, distance < (closest?.1 ?? Float.greatestFiniteMagnitude) { closest = (joint, distance) }
            }
            if let closest {
                onSelectBone?(closest.0, event.modifierKeys.contains(.main) || event.modifierKeys.contains(.control) || event.modifierKeys.contains(.shift))
            }
        }
    }

    func selectedWorldPoints() -> [Vector3] {
        guard let player = capturedAnimationPlayer() else { return [] }
        return selectedNodeIndices.sorted().compactMap { index in
            guard player.globalTransforms.indices.contains(index) else { return nil }
            return (normalizationTransform.matrix * player.globalTransforms[index] * Vector4(0, 0, 0, 1)).xyz
        }
    }
}
