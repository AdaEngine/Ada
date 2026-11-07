import AdaAssets
import AdaECS
import AdaGeometry
import AdaTransform
import Foundation
import Math

/// A source entity pose to install at the same world boundary as its joined surface.
public struct MeshTerrainSourceTransform: Sendable {
    public let entity: Entity.ID
    public let transform: Transform3D
    private let authoredPose: Transform?

    public init(entity: Entity.ID, transform: Transform3D) {
        self.entity = entity; self.transform = transform; authoredPose = nil
    }

    /// Retains the exact authored TRS, including signed scales, during editor drags.
    public init(entity: Entity.ID, pose: Transform) {
        self.entity = entity; transform = pose.matrix; authoredPose = pose
    }

    func resolvedPose() throws -> Transform {
        try ScalarSolid.validateTransform(transform)
        if let authoredPose { return authoredPose }
        var scale = transform.scale
        if transform.determinant < 0 { scale.x = -scale.x }
        let rotation = Transform3D(x: Vector4(transform.x.xyz / scale.x, 0), y: Vector4(transform.y.xyz / scale.y, 0),
                                   z: Vector4(transform.z.xyz / scale.z, 0), w: [0, 0, 0, 1]).rotation.normalized
        let pose = Transform(rotation: rotation, scale: scale, position: transform.origin)
        // An ECS pose is TRS. Shear must be represented in operand geometry,
        // never silently discarded while publishing an object's local pose.
        let rebuilt = pose.matrix
        for column in 0..<4 { for row in 0..<4 {
            guard abs(rebuilt[column, row] - transform[column, row]) <= 0.0001 * max(1, abs(transform[column, row])) else {
                throw TriangleGeometryError.invalidInput
            }
        } }
        return pose
    }
}

/// Optimistic authoring request. The previously accepted generation remains live
/// until geometry, instances, queries, collision and source poses are ready.
public struct MeshTerrain3DEdit: Component, Sendable {
    public let id: UUID
    var bindingChanges: [MeshTerrainBindingOwnership] = []
    public let expectedInputKey: Data
    public let candidate: MeshTerrainDocumentAsset
    public let sourceTransforms: [MeshTerrainSourceTransform]
    /// Nil retains existing replacements; an empty list detaches every source draw owned by this terrain.
    public let drawReplacements: [MeshTerrainDrawReplacement]?
    /// Static source bodies replaced by this generation. Nil retains ownership; [] restores all.
    public let collisionReplacements: [Entity.ID]?
    /// A newly staged immutable manifest to adopt with this generation, after its compiled input is verified.
    public let adoptionManifest: String?
    /// Scene bindings are installed with the matching geometry, never one frame earlier or later.
    public let bindingUpdates: [MeshTerrainBindingUpdate]
    let ticket: MeshTerrainEditTicket?
    public init(expectedInputKey: Data, candidate: MeshTerrainDocumentAsset, sourceTransforms: [MeshTerrainSourceTransform] = [],
                drawReplacements: [MeshTerrainDrawReplacement]? = nil, collisionReplacements: [Entity.ID]? = nil, adoptionManifest: String? = nil,
                bindingUpdates: [MeshTerrainBindingUpdate] = [], ticket: MeshTerrainEditTicket? = nil) {
        id = UUID(); self.expectedInputKey = expectedInputKey; self.candidate = candidate; self.sourceTransforms = sourceTransforms
        self.drawReplacements = drawReplacements; self.collisionReplacements = collisionReplacements
        self.adoptionManifest = adoptionManifest
        self.bindingUpdates = bindingUpdates; self.ticket = ticket
    }
}

public enum MeshTerrainEditPhase: Sendable { case pending, applied, failed, cancelled }
public struct MeshTerrain3DEditStatus: Component, Sendable {
    public let id: UUID
    public let phase: MeshTerrainEditPhase
    public let error: String?
}
