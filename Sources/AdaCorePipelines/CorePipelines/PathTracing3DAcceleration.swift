@_spi(Internal) import AdaRender
import Math

/// Identifies the geometry of one mesh part, so every placement of it shares one bottom-level structure.
struct PathTracing3DPartKey: Hashable, Sendable {
    let vertexBuffer: ObjectIdentifier
    let indexBuffer: ObjectIdentifier
    let indexCount: Int
}

extension PathTracing3DPartKey {
    init(_ part: Mesh.Part) {
        self.init(
            vertexBuffer: ObjectIdentifier(part.vertexBuffer),
            indexBuffer: ObjectIdentifier(part.indexBuffer),
            indexCount: min(part.indexCount, part.meshDescriptor.indicies.count)
        )
    }
}

/// One placed mesh part at its world transform.
struct PathTracing3DPlacement: Sendable {
    var key: PathTracing3DPartKey
    var transform: Transform3D
    var castsShadows: Bool
    /// Number of primitives in the shared part's index buffer.
    var triangleCount: Int
}

/// The top-level instances for a list of placements, in table order.
struct PathTracing3DInstancePlan: Sendable {
    struct Instance: Sendable {
        var key: PathTracing3DPartKey
        var transform: Transform3D
        var mask: UInt8
        /// Row containing this placement's shared geometry offset, material, shadow flags and distance limit.
        var metadataIndex: UInt32
    }

    /// Every ray sees every instance; shadow rays use this bit to see only shadow casters.
    static let shadowCasterMask: UInt8 = 1

    var instances: [Instance] = []
    var triangleTotal = 0

    /// Preserves the placement order of the shader's per-instance metadata.
    static func make(_ placements: [PathTracing3DPlacement]) -> Self {
        var plan = Self()
        for placement in placements where placement.triangleCount > 0 {
            plan.instances.append(
                Instance(
                    key: placement.key,
                    transform: placement.transform,
                    // Bit 1 is set on every instance so primary rays (mask 0xff) hit all of them; bit 0 marks shadow casters.
                    mask: placement.castsShadows ? 0b11 : 0b10,
                    metadataIndex: UInt32(plan.instances.count)
                )
            )
            plan.triangleTotal += placement.triangleCount
        }
        return plan
    }
}

/// Bottom-level structures per part and the top-level structure of a view, with their lifetimes.
///
/// `@unchecked Sendable`: the owner is only mutated from the path tracing render node through `@ResMut`, which gives it
/// exclusive access for the duration of the node's execution; it has no other users.
final class PathTracing3DAccelerationStructures: @unchecked Sendable {
    struct Resolved {
        var structure: any AccelerationStructure
        /// True when the structure was just created and must be built by the caller.
        var isNew: Bool
    }

    private(set) var bottoms: [PathTracing3DPartKey: (structure: any AccelerationStructure, triangles: Int, retained: [AnyObject])] = [:]
    private(set) var top: (structure: any AccelerationStructure, capacity: Int)?

    /// The part's bottom-level structure, created (and flagged new) the first time it is needed or when its size changed.
    ///
    /// `retained` objects (the part's buffers) stay alive with the entry, so a key made from their identities cannot be
    /// reused by different geometry while the entry exists.
    func resolveBottom(
        _ key: PathTracing3DPartKey,
        triangleCount: Int,
        retaining retained: [AnyObject] = [],
        create: (Int) -> (any AccelerationStructure)?
    ) -> Resolved? {
        if let existing = bottoms[key], existing.triangles == triangleCount {
            return Resolved(structure: existing.structure, isNew: false)
        }
        guard let structure = create(triangleCount) else {
            return nil
        }
        bottoms[key] = (structure, triangleCount, retained)
        return Resolved(structure: structure, isNew: true)
    }

    /// The view's top-level structure. Its capacity grows (to the next power of two) only when `instanceCount` exceeds it,
    /// so ordinary frames rebuild the same structure in place.
    func resolveTop(instanceCount: Int, create: (Int) -> (any AccelerationStructure)?) -> Resolved? {
        if let top, instanceCount <= top.capacity {
            return Resolved(structure: top.structure, isNew: false)
        }
        var capacity = 16
        while capacity < instanceCount { capacity *= 2 }
        guard let structure = create(capacity) else {
            return nil
        }
        top = (structure, capacity)
        return Resolved(structure: structure, isNew: true)
    }

    /// Releases bottom-level structures whose parts are no longer placed; returns the evicted keys.
    @discardableResult
    func retain(_ keys: Set<PathTracing3DPartKey>) -> [PathTracing3DPartKey] {
        let evicted = bottoms.keys.filter { !keys.contains($0) }
        for key in evicted { bottoms.removeValue(forKey: key) }
        return Array(evicted)
    }

    func removeAll() {
        bottoms = [:]
        top = nil
    }
}
