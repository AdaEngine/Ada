import AdaECS
import AdaRender
import AdaTransform
import AdaUtils
import Logging
import Math
import OrderedCollections

enum TileMapChunkBuilder {
    static func build(
        cells: OrderedDictionary<PointInt, TileMapLayer.TileCellData>,
        layer: TileMapLayer,
        tileSize: Size,
        revision: UInt64
    ) -> TileMapRenderedChunk {
        var atlas: [TileMapRenderedAtlasTile] = []
        var dynamic: [TileMapRenderedAtlasTile] = []
        var entities: [TileMapChunkCell] = []
        var polygons: [[Vector2]] = []
        var minimum: Vector3?
        var maximum: Vector3?
        let validSize = tileSize.width.isFinite && tileSize.height.isFinite && tileSize.width > 0 && tileSize.height > 0
        for (position, cell) in cells where validSize {
            let center = Vector3(Float(position.x) * tileSize.width, Float(position.y) * tileSize.height, Float(layer.zIndex))
            guard center.x.isFinite, center.y.isFinite, center.z.isFinite else {
                continue
            }
            let half = Vector3(tileSize.width * 0.5, tileSize.height * 0.5, 0)
            minimum = minimum.map { min($0, center - half) } ?? center - half
            maximum = maximum.map { max($0, center + half) } ?? center + half
            guard let source = layer.tileSet?.sources[cell.sourceId] else {
                Logger(label: "org.adaengine.tilemap").critical("Tile source not found: \(cell.sourceId), layer \(layer.id)")
                continue
            }
            if let source = source as? TextureAtlasTileSource {
                let data = source.getTileData(at: cell.atlasCoordinates)
                let ring = cell.occlusion.map { $0.mode == .disabled ? nil : $0.points } ?? data.occluderPolygon
                let referenceSize = cell.occlusion != nil ? cell.occlusion?.referenceSize : data.occluderReferenceSize
                if let ring, (try? TileOcclusionPolygon.validate(ring, referenceSize: referenceSize)) != nil {
                    let scale = referenceSize.map { Vector2(tileSize.width / $0.width, tileSize.height / $0.height) } ?? Vector2(1, 1)
                    let matrix = cell.orientation.transform(at: center, tileSize: tileSize).matrix
                    polygons.append(ring.map { point in
                        let local = point * scale
                        let transformed = matrix * Vector4(local.x, local.y, 0, 1)
                        return Vector2(transformed.x, transformed.y)
                    })
                }
                let texture = source.getTexture(at: cell.atlasCoordinates)
                let tile = TileMapRenderedAtlasTile(
                    texture: texture,
                    tintColor: data.modulateColor,
                    transform: cell.orientation.transform(at: center, tileSize: tileSize)
                )
                if texture is AnimatedTexture {
                    dynamic.append(tile)
                } else {
                    atlas.append(tile)
                }
            } else if source is TileEntityAtlasSource {
                entities.append(TileMapChunkCell(position: position, data: cell))
            } else {
                Logger(label: "org.adaengine.tilemap").warning("Unsupported tile source: \(cell.sourceId)")
            }
        }
        let bounds: AABB
        if let minimum, let maximum { bounds = AABB(min: minimum, max: maximum) } else { bounds = .empty }
        return TileMapRenderedChunk(revision: revision, atlasTiles: atlas, dynamicTiles: dynamic, entityCells: entities, bounds: bounds, tileSize: tileSize, occluderPolygons: polygons)
    }
}
