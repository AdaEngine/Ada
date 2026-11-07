import AdaEngine
import Math
import Observation

/// Editable Inspector state for one scene/model/modifier selection, independent of resource settings.
@Observable
@MainActor
final class EditorIKSceneBindingDraft {
    var targetEntity = ""
    var poleEntity = ""
    var targetOffset: [String] = ["0", "0", "0"]
    var poleOffset: [String] = ["0", "0", "0"]
    var targetUsesModelPoint = false
    var poleUsesModelPoint = false
    private(set) var sceneRevision = ""

    func load(_ binding: AnimationIKBinding3D?, sceneRevision: String) {
        self.sceneRevision = sceneRevision
        targetEntity = binding?.target?.entity ?? ""
        poleEntity = binding?.pole?.entity ?? ""
        targetUsesModelPoint = binding?.target != nil && binding?.target?.entity == nil
        poleUsesModelPoint = binding?.pole != nil && binding?.pole?.entity == nil
        targetOffset = Self.fields(binding?.target?.point ?? .zero)
        poleOffset = Self.fields(binding?.pole?.point ?? .zero)
    }

    func binding() throws -> AnimationIKBinding3D {
        let result = try AnimationIKBinding3D(
            target: point(entity: targetEntity, fields: targetOffset, usesModelPoint: targetUsesModelPoint),
            pole: point(entity: poleEntity, fields: poleOffset, usesModelPoint: poleUsesModelPoint)
        )
        try result.validate()
        return result
    }

    private func point(entity: String, fields: [String], usesModelPoint: Bool) throws -> AnimationIKTarget3D? {
        if entity.isEmpty, !usesModelPoint { return nil }
        let values = fields.compactMap(Float.init)
        guard values.count == 3, values.allSatisfy(\.isFinite) else { throw AnimationPoseModifierError.invalidModifier("scene point") }
        return .init(entity: entity.isEmpty ? nil : entity, point: Vector3(values[0], values[1], values[2]))
    }

    private static func fields(_ point: Vector3) -> [String] { [point.x, point.y, point.z].map { String($0) } }
}
