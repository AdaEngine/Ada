//
//  TileMapComponent.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/4/24.
//

import AdaECS
import Math

/// Component that responsible to display ``TileMap`` instance on screen.
@Component
public struct TileMapComponent {
    /// Contains ``TileMap`` instance that will display on screen.
    public var tileMap: TileMap

    /// The size to use for each tile
    public var tileDisplaySize: Size

    /// Contains information about entities
    ///
    /// Each tile layer contains root entity that holds tile sprite entitis with physic bodies.
    internal var tileLayers: [TileMapLayer.ID: Entity.ID] = [:]

    /// The map revision rendered for this component's owner.
    internal var lastRenderedTileMapRevision: UInt64?

    /// The map identity rendered for this component's owner.
    internal var lastRenderedTileMapID: ObjectIdentifier?

    /// The layer revisions rendered for this component's owner.
    internal var lastRenderedLayerRevisions: [TileMapLayer.ID: UInt64] = [:]

    /// The tile display size used for this component's last render.
    internal var lastRenderedTileDisplaySize: Size?

    public init(tileMap: TileMap, tileDisplaySize: Size) {
        self.tileMap = tileMap
        self.tileDisplaySize = tileDisplaySize
    }
}
