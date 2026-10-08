import AdaECS
import AdaRender
import AdaTransform
import AdaUtils
import Math

/// Static atlas geometry uses cached, independently culled chunks by default.
/// The sprites mode retains the reference per-tile render path for validation and unusual ordering.
public enum TileMapRenderMode: String, Sendable {
    case chunks
    case sprites
}

struct TileMapChunkCoordinate: Hashable, Sendable {
    static let side = 32
    let x: Int
    let y: Int

    init(cell: PointInt) {
        func floorDivide(_ value: Int) -> Int {
            let quotient = value / Self.side
            return value % Self.side < 0 ? quotient - 1 : quotient
        }
        self.x = floorDivide(cell.x)
        self.y = floorDivide(cell.y)
    }
}

struct TileMapChunkCell: Sendable {
    let position: PointInt
    let data: TileMapLayer.TileCellData
}

/// Immutable snapshot; identity is also the lifetime/key of its cached GPU geometry.
final class TileMapRenderedChunk: Sendable {
    let revision: UInt64
    let atlasTiles: [TileMapRenderedAtlasTile]
    let dynamicTiles: [TileMapRenderedAtlasTile]
    let entityCells: [TileMapChunkCell]
    let occluderPolygons: [[Vector2]]
    let bounds: AABB
    let tileSize: Size

    init(revision: UInt64, atlasTiles: [TileMapRenderedAtlasTile], dynamicTiles: [TileMapRenderedAtlasTile], entityCells: [TileMapChunkCell], bounds: AABB, tileSize: Size, occluderPolygons: [[Vector2]] = []) {
        self.revision = revision
        self.atlasTiles = atlasTiles
        self.dynamicTiles = dynamicTiles
        self.entityCells = entityCells
        self.occluderPolygons = occluderPolygons
        self.bounds = bounds
        self.tileSize = tileSize
    }

    func worldBounds(model: Transform3D) -> AABB {
        let center = (model * Vector4(bounds.center, 1)).xyz
        let half = bounds.halfExtents
        return AABB(center: center, halfExtents: Vector3(
            abs(model.x.x) * half.x + abs(model.y.x) * half.y + abs(model.z.x) * half.z,
            abs(model.x.y) * half.x + abs(model.y.y) * half.y + abs(model.z.y) * half.z,
            abs(model.x.z) * half.x + abs(model.y.z) * half.y + abs(model.z.z) * half.z
        ))
    }
}

struct ExtractedTileMapChunk: Sendable {
    let ownerID: Entity.ID
    let chunk: TileMapRenderedChunk
    let model: Transform3D
    let ignoresFrustum: Bool
}

struct ExtractedTileMapChunks: Resource {
    var chunks: [ExtractedTileMapChunk] = []
}
