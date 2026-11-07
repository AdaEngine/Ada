import AdaECS
import AdaGeometry
import AdaTransform
import Foundation

/// Stable authored identity shared by scene payloads and retained terrain bindings.
public struct MeshTerrain3DIdentity: Component, Codable, Equatable, Sendable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

/// A static model part below the bound source root. Paths follow authored child order.
/// An empty selection includes the eligible opaque static parts below that root.
public struct MeshTerrainPartSelection: Codable, Hashable, Sendable {
    public var nodePath: [Int]
    public var model: Int
    public var part: Int
    public init(nodePath: [Int] = [], model: Int = 0, part: Int = 0) {
        self.nodePath = nodePath; self.model = model; self.part = part
    }
}

/// Retains the reusable source object while its selected triangles participate in terrain.
public struct MeshTerrain3DBinding: Component, Codable, Equatable, Sendable {
    public var target: UUID
    public let modifier: UUID
    public let sourceID: UInt32
    public var operation: MeshTerrainModifierOperation
    public var parts: [MeshTerrainPartSelection]
    public var enabled: Bool
    public var contactWidth: Float
    public init(target: UUID, modifier: UUID = UUID(), sourceID: UInt32, operation: MeshTerrainModifierOperation = .union,
                parts: [MeshTerrainPartSelection] = [], enabled: Bool = true, contactWidth: Float = 1) {
        self.target = target; self.modifier = modifier; self.sourceID = sourceID; self.operation = operation
        self.parts = parts; self.enabled = enabled; self.contactWidth = contactWidth
    }
}

/// A provisional local pose. The accepted source pose remains visible until its matching surface is ready.
public struct MeshTerrain3DProposedPose: Component, Sendable {
    public let id: UUID
    public let pose: Transform
    let ticket: MeshTerrainEditTicket?

    public init(_ pose: Transform, ticket: MeshTerrainEditTicket? = nil) {
        id = UUID(); self.pose = pose; self.ticket = ticket
    }
}

public enum MeshTerrainBindingPhase: Sendable { case pending, applied, failed, orphaned }
public struct MeshTerrain3DBindingStatus: Component, Sendable {
    public let phase: MeshTerrainBindingPhase
    public let error: String?
}
