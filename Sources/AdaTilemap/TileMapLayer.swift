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
    struct TileCellData {
        /// Position in atlas
        let atlasCoordinates: PointInt
        /// where get a tile
        let sourceId: TileSource.ID
        let orientation: TileOrientation
    }

    /// The tile cells of the tile map layer.
    private(set) var tileCells: OrderedDictionary<PointInt, TileCellData> = [:] {
        didSet {
            self.setNeedsUpdate()
        }
    }

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
        self.tileCells[position] = TileCellData(
            atlasCoordinates: atlasCoordinates,
            sourceId: sourceId,
            orientation: orientation
        )
    }

    /// Remove a cell from the tile map layer.
    ///
    /// - Parameter position: The position of the cell.
    public func removeCell(at position: PointInt) {
        self.tileCells[position] = nil
    }

    /// Remove all cells from the tile map layer.
    public func removeAllCells() {
        self.tileCells = [:]
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
        tileCells[position] = TileCellData(atlasCoordinates: cell.atlasCoordinates, sourceId: cell.sourceId, orientation: orientation)
    }

    // MARK: - Internals

    /// Set the tile map layer needs update.
    func setNeedsUpdate() {
        self.needUpdates = true
        self.updateRevision &+= 1
    }

    /// Update the tile map layer did finish.
    func updateDidFinish() {
        self.needUpdates = false
    }
}
