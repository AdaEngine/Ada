//
//  TileEntityAtlasSource.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/10/24.
//

import AdaECS
import AdaUtils
import Math

public class TileEntityAtlasSource: TileSource, @unchecked Sendable {
    struct EntityTileData {
        var entity: Entity

        var tileData: TileData
    }

    private(set) var tiles: [PointInt: EntityTileData] = [:]

    override public init() {
        super.init()
    }

    // MARK: - Codable

    public required init(from _: any Decoder) throws {
        fatalErrorMethodNotImplemented()
    }

    override public func encode(to _: any Encoder) throws {
        fatalErrorMethodNotImplemented()
    }

    // MARK: - Public

    public func createTile(at atlasCoordinates: PointInt, for entity: Entity) {
        let tileData = TileData()
        let data = EntityTileData(entity: entity, tileData: tileData)
        self.tiles[atlasCoordinates] = data
    }

    /// Returns a fresh entity instance for the tile template.
    ///
    /// Component values are copied from the stored template. Parent and child
    /// relationships are cleared so repeated cells cannot share hierarchy state
    /// with one another or with the template.
    public func getEntity(at atlasCoordinates: PointInt) -> Entity {
        guard let data = self.tiles[atlasCoordinates] else {
            fatalError("Entity not found at coordinates \(atlasCoordinates)")
        }

        let entity = data.entity.copy()
        entity.components[RelationshipComponent.self] = RelationshipComponent()
        return entity
    }

    public func removeTile(at atlasCoordinates: PointInt) {
        self.tiles.removeValue(forKey: atlasCoordinates)
    }

    override func getTileData(at atlasCoordinates: PointInt) -> TileData {
        return self.tiles[atlasCoordinates]?.tileData ?? TileData()
    }
}
