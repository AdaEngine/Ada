import AdaAnimation
import AdaECS
import AdaTransform
import Math

/// Stable authored identity within a loaded scene instance. Runtime Entity.ID is never serialized as a target.
public struct AnimationSceneIdentity3D: Component, Sendable {
    public var namespace: String
    public var id: String

    public init(namespace: String, id: String) { self.namespace = namespace; self.id = id }
}

/// One pre-modifier snapshot for all model instances. Stops at transformless gaps, like ChildTransformSystem.
struct AnimationIKSnapshot3D {
    struct Identity: Hashable { var namespace: String; var id: String }
    var locals: [Entity.ID: Transform3D] = [:]
    var parents: [Entity.ID: Entity.ID] = [:]
    var identities: [Identity: Entity.ID] = [:]
    var ambiguous: Set<Identity> = []
    var roots: Set<Entity.ID> = []

    mutating func insert(_ identity: AnimationSceneIdentity3D, entity: Entity.ID) {
        let key = Identity(namespace: identity.namespace, id: identity.id)
        if identities.updateValue(entity, forKey: key) != nil { ambiguous.insert(key) }
    }

    func inputs(for animation: ModelAnimation3DComponent, root: Entity.ID) -> [String: AnimationPoseModifierInput] {
        var result: [String: AnimationPoseModifierInput] = [:]
        guard animation.player.hasActivePoseModifiers else { return result }
        let owner = resolve(root)
        let ownerSupported = owner.map { Self.supported($0) } ?? false
            && supportsHierarchy(root) && !(parents[root].map(isAnimated) ?? false)
        let inverse = ownerSupported ? owner?.inverse : nil
        for modifier in animation.player.poseModifiers where modifier.enabled {
            let binding = animation.modifierBindings[modifier.id]
            let target: Vector3?
            let pole: Vector3?
            if let override = binding?.target { target = resolve(override, namespace: animation.modifierNamespace, inverseOwner: inverse) }
            else { target = modifier.target }
            if let override = binding?.pole { pole = resolve(override, namespace: animation.modifierNamespace, inverseOwner: inverse) }
            else { pole = modifier.pole }
            let missingPole = binding?.pole != nil && pole == nil
            result[modifier.id] = .init(target: missingPole ? nil : target, pole: pole, supportsTransform: ownerSupported)
        }
        return result
    }

    private func resolve(_ target: AnimationIKTarget3D, namespace: String, inverseOwner: Transform3D?) -> Vector3? {
        guard (try? target.validate()) != nil else { return nil }
        guard let id = target.entity else { return target.point }
        let key = Identity(namespace: namespace, id: id)
        guard !ambiguous.contains(key), let entity = identities[key], !isAnimated(entity),
              let global = resolve(entity), let inverseOwner else { return nil }
        let point = (inverseOwner * global * Vector4(target.point, 1)).xyz
        return point.x.isFinite && point.y.isFinite && point.z.isFinite ? point : nil
    }

    private func isAnimated(_ entity: Entity.ID) -> Bool {
        var current: Entity.ID? = entity
        var visited: Set<Entity.ID> = []
        while let id = current {
            guard visited.insert(id).inserted else { return true }
            if roots.contains(id) { return true }
            current = parents[id]
        }
        return false
    }

    private func resolve(_ entity: Entity.ID) -> Transform3D? {
        guard var matrix = locals[entity] else { return nil }
        var current = parents[entity]
        var visited: Set<Entity.ID> = [entity]
        while let id = current, let parent = locals[id] {
            guard visited.insert(id).inserted else { return nil }
            matrix = parent * matrix
            current = parents[id]
        }
        return matrix
    }

    private func supportsHierarchy(_ entity: Entity.ID) -> Bool {
        var current: Entity.ID? = entity
        var visited: Set<Entity.ID> = []
        while let id = current, let local = locals[id] {
            guard visited.insert(id).inserted, Self.supported(local) else { return false }
            current = parents[id]
        }
        return true
    }

    private static func supported(_ matrix: Transform3D) -> Bool {
        let x = matrix.x.xyz, y = matrix.y.xyz, z = matrix.z.xyz
        let scale = x.length
        guard scale.isFinite, scale > 1e-8, matrix.origin.x.isFinite, matrix.origin.y.isFinite, matrix.origin.z.isFinite else { return false }
        let nx = x / scale, ny = y / scale, nz = z / scale
        return abs(ny.length - 1) < 0.0001 && abs(nz.length - 1) < 0.0001
            && abs(nx.dot(ny)) < 0.0001 && abs(nx.dot(nz)) < 0.0001 && abs(ny.dot(nz)) < 0.0001
            && nx.cross(ny).dot(nz) > 0.9999
    }
}
