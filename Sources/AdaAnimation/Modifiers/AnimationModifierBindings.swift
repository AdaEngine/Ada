import Math

/// With an entity ID, `point` is an offset in that entity's local space; otherwise it is a model-space point.
public struct AnimationIKTarget3D: Codable, Equatable, Sendable {
    public var entity: String?
    public var point: Vector3

    public init(entity: String? = nil, point: Vector3 = .zero) { self.entity = entity; self.point = point }

    public func validate() throws {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite,
              entity.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else {
            throw AnimationPoseModifierError.invalidModifier(entity ?? "target")
        }
    }
}

/// Instance overrides for a stable modifier ID. Nil members retain the resource's model-space point.
public struct AnimationIKBinding3D: Codable, Equatable, Sendable {
    public var target: AnimationIKTarget3D?
    public var pole: AnimationIKTarget3D?

    public init(target: AnimationIKTarget3D? = nil, pole: AnimationIKTarget3D? = nil) { self.target = target; self.pole = pole }

    public func validate() throws { try target?.validate(); try pole?.validate() }
}
