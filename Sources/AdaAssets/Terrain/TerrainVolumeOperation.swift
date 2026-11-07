import Foundation
import Math

/// A reusable operand source. Static mesh paths are portable relative to the terrain manifest.
public enum TerrainVolumeOperand: Codable, Equatable, Sendable {
    case primitive(ScalarSolidPrimitive)
    case mesh(assetPath: String, scene: Int?)
}

/// Ordered non-destructive solid edit. Array order determines evaluation order; identity survives reordering.
public struct TerrainVolumeOperation: Codable, Equatable, Sendable {
    public let id: UUID
    public let operation: ScalarBooleanOperation
    public let operand: TerrainVolumeOperand
    public let transform: Transform3D
    public let layerID: UInt16?
    public let isEnabled: Bool

    public init(
        id: UUID = UUID(),
        operation: ScalarBooleanOperation,
        operand: TerrainVolumeOperand,
        transform: Transform3D = .identity,
        layerID: UInt16? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id; self.operation = operation; self.operand = operand; self.transform = transform; self.layerID = layerID; self.isEnabled = isEnabled
    }

    public func validate() throws {
        try ScalarSolid.validateTransform(transform)
        switch operand {
        case let .primitive(primitive): _ = try ScalarSolid(primitive: primitive, transform: transform)
        case let .mesh(path, scene): try TerrainMeshPrototypeReference(id: 0, assetPath: path, scene: scene).validate()
        }
    }
}

/// Immutable cache resource, addressed in the document's signed 32-cell lattice.
public struct TerrainVolumeBrickReference: Codable, Equatable, Sendable {
    public let x: Int32
    public let y: Int32
    public let z: Int32
    public let fileName: String

    public init(x: Int32, y: Int32, z: Int32, fileName: String) { self.x = x; self.y = y; self.z = z; self.fileName = fileName }
}
