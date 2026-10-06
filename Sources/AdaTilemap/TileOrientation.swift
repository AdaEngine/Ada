import AdaTransform
import Math

/// Orientation inside a tile cell. Quarter turns are counterclockwise in Y-up space;
/// reflected variants mirror X before rotating. Raw values 0...7 are portable cell IDs.
public enum TileOrientation: Int, Codable, CaseIterable, Sendable {
    case identity = 0
    case rotate90 = 1
    case rotate180 = 2
    case rotate270 = 3
    case mirrorX = 4
    case mirrorXRotate90 = 5
    case mirrorXRotate180 = 6
    case mirrorXRotate270 = 7

    /// Builds a transform shared by atlas tiles, entity tiles and their shadow geometry.
    /// Rectangular tiles stay inside their original cell after a quarter turn.
    func transform(at position: Vector3, tileSize: Size) -> Transform {
        let quarterTurns = rawValue % 4
        let mirrored: Float = rawValue >= 4 ? -1 : 1
        var scale = Vector3(mirrored, 1, 1)
        if quarterTurns % 2 == 1, tileSize.width > 0, tileSize.height > 0 {
            let horizontal = tileSize.height / tileSize.width
            let vertical = tileSize.width / tileSize.height
            if horizontal.isFinite, vertical.isFinite {
                scale = Vector3(mirrored * horizontal, vertical, 1)
            }
        }
        return Transform(
            rotation: Quat(axis: [0, 0, 1], angle: Float(quarterTurns) * .pi / 2),
            scale: scale,
            position: position
        )
    }
}
