import AdaAssets
import Foundation
import Math

struct TerrainVolumeBaseCell: Equatable, Sendable {
    let coordinate: TerrainTileCoordinate
    let width: Int32
    let depth: Int32
    let pageGeneration: UUID?
}

struct TerrainVolumeOperandDependency: Equatable, Sendable {
    let operation: TerrainVolumeOperation
    let meshGeneration: UUID?
}

struct TerrainVolumeBrickDependency: Equatable, Sendable {
    static let maximumBaseCells = 4_096
    let baseIdentity: UUID
    let baseCells: [TerrainVolumeBaseCell]
    let origin: Vector3
    let cellSize: Float
    let interiorLayerID: UInt16?
    let operands: [TerrainVolumeOperandDependency]
}
