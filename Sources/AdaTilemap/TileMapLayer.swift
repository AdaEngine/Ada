//
//  TileMapLayer.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/5/24.
//

import AdaUtils
import Math
import OrderedCollections

/// A layer of a tile map.
public class TileMapLayer: Identifiable, @unchecked Sendable {
    /// The name of the tile map layer.
    public var name: String = ""

    /// The id of the tile map layer.
    public var id: Int = RID().id

    /// The tile set of the tile map layer.
    public internal(set) weak var tileSet: TileSet?

    /// The tile map of the tile map layer.
    public internal(set) weak var tileMap: TileMap?

    /// The z index of the tile map layer.
    public var zIndex: Int = 0 {
        didSet {
            self.setNeedsUpdate()
        }
    }

    /// A data structure that contains the atlas coordinates and the source id of a tile.
    struct TileCellData: Equatable, Sendable {
        /// Position in atlas
        let atlasCoordinates: PointInt
        /// where get a tile
        let sourceId: TileSource.ID
        let orientation: TileOrientation
        var occlusion: TileOcclusionOverride?
    }

    /// The tile cells of the tile map layer.
    private(set) var tileCells: OrderedDictionary<PointInt, TileCellData> = [:]
    private(set) var chunkCells: [TileMapChunkCoordinate: OrderedDictionary<PointInt, TileCellData>] = [:]
    private(set) var chunkRevisions: [TileMapChunkCoordinate: UInt64] = [:]
    private(set) var fullUpdateRevision: UInt64 = 0

    /// A Boolean value indicating whether the tile map layer is enabled.
    public var isEnabled: Bool = true {
        didSet {
            self.tileMap?.setNeedsUpdate()
        }
    }

    /// A Boolean value indicating whether the tile map layer needs to be updated.
    internal private(set) var needUpdates = false {
        didSet {
            if needUpdates {
                self.tileMap?.setNeedsUpdate(advanceRevision: false)
            }
        }
    }

    /// The revision of this layer's renderable state.
    internal private(set) var updateRevision: UInt64 = 0

    /// Set a cell for the tile map layer.
    ///
    /// - Parameters:
    ///   - position: The position of the cell.
    ///   - sourceId: The source id of the cell.
    ///   - atlasCoordinates: The atlas coordinates of the cell.
    ///   - orientation: The orientation inside the cell; identity preserves existing resources.
    public func setCell(at position: PointInt, sourceId: TileSource.ID, atlasCoordinates: PointInt, orientation: TileOrientation = .identity) {
        let cell = TileCellData(
            atlasCoordinates: atlasCoordinates,
            sourceId: sourceId,
            orientation: orientation,
            occlusion: tileCells[position]?.occlusion
        )
        guard tileCells[position] != cell else {
            return
        }
        tileCells[position] = cell
        let coordinate = TileMapChunkCoordinate(cell: position)
        chunkCells[coordinate, default: [:]][position] = cell
        recordCellChange(in: coordinate)
    }

    /// Remove a cell from the tile map layer.
    ///
    /// - Parameter position: The position of the cell.
    public func removeCell(at position: PointInt) {
        guard tileCells.removeValue(forKey: position) != nil else {
            return
        }
        let coordinate = TileMapChunkCoordinate(cell: position)
        chunkCells[coordinate]?[position] = nil
        recordCellChange(in: coordinate)
        if chunkCells[coordinate]?.isEmpty == true {
            chunkCells[coordinate] = nil
            chunkRevisions[coordinate] = nil
        }
    }

    /// Remove all cells from the tile map layer.
    public func removeAllCells() {
        self.tileCells = [:]
        chunkCells.removeAll()
        chunkRevisions.removeAll()
        setNeedsUpdate()
    }

    /// Get the tile source of a cell.
    ///
    /// - Parameter position: The position of the cell.
    /// - Returns: Return TileSource identifier or ``TileSource.invalidSource``.
    public func getCellTileSource(at position: PointInt) -> TileSource.ID {
        return self.tileCells[position]?.sourceId ?? TileSource.invalidSource
    }

    /// Get the atlas coordinates of a cell.
    ///
    /// - Parameter position: The position of the cell.
    /// - Returns: The atlas coordinates of the cell.
    public func getCellAtlasCoordinates(at position: PointInt) -> PointInt {
        return self.tileCells[position]?.atlasCoordinates ?? PointInt(x: 0, y: 0)
    }

    /// Returns the cell's orientation, or identity for an empty cell.
    public func getCellOrientation(at position: PointInt) -> TileOrientation {
        self.tileCells[position]?.orientation ?? .identity
    }

    /// Changes an existing cell's orientation and invalidates every consumer of this layer.
    public func setCellOrientation(_ orientation: TileOrientation, at position: PointInt) {
        guard let cell = tileCells[position], cell.orientation != orientation else {
            return
        }
        setCell(at: position, sourceId: cell.sourceId, atlasCoordinates: cell.atlasCoordinates, orientation: orientation)
    }

    /// Returns the cell override, or nil when it inherits its atlas tile's occlusion.
    public func getCellOcclusion(at position: PointInt) -> TileOcclusionOverride? { tileCells[position]?.occlusion }

    /// Overrides occlusion on an existing cell. Nil restores inheritance; only its chunk is invalidated.
    public func setCellOcclusion(_ occlusion: TileOcclusionOverride?, at position: PointInt) {
        guard var cell = tileCells[position], cell.occlusion != occlusion else {
            return
        }
        cell.occlusion = occlusion
        tileCells[position] = cell
        let coordinate = TileMapChunkCoordinate(cell: position)
        chunkCells[coordinate]?[position] = cell
        recordCellChange(in: coordinate)
    }

    // MARK: - Internals

    /// Set the tile map layer needs update.
    func setNeedsUpdate() {
        self.needUpdates = true
        self.updateRevision &+= 1
        self.fullUpdateRevision &+= 1
    }

    private func recordCellChange(in coordinate: TileMapChunkCoordinate) {
        needUpdates = true
        updateRevision &+= 1
        chunkRevisions[coordinate] = updateRevision
    }

    /// Update the tile map layer did finish.
    func updateDidFinish() {
        self.needUpdates = false
    }
}
