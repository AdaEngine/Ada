import AdaECS
import AdaTilemap
import Math

/// Runs after query iteration, under the scheduler's deferred world access.
enum AdaScriptTileOrientationCommand {
    static func enqueue(
        commands: Commands,
        entity: Int,
        layer: Int,
        x: Int,
        y: Int,
        orientation: Int,
        reportDiagnostic: @escaping @Sendable (String) -> Void
    ) -> Bool {
        guard entity >= 0, layer >= 0, let orientation = TileOrientation(rawValue: orientation) else {
            reportDiagnostic("Tile orientation requires an entity, a nonnegative layer and an orientation ID from 0 to 7")
            return false
        }
        commands.queue.push { world in
            guard let component = world.get(TileMapComponent.self, from: entity), component.tileMap.layers.indices.contains(layer) else {
                reportDiagnostic("Tile orientation target or layer is unavailable")
                return
            }
            component.tileMap.layers[layer].setCellOrientation(orientation, at: PointInt(x: x, y: y))
        }
        return true
    }
}
