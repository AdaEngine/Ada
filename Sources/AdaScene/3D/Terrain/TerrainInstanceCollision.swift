/// Limits optional static collision for placements carrying TerrainInstanceFlags.collision.
/// Distance is measured horizontally in terrain-local units, like terrain residency and brush radii.
public struct TerrainInstanceCollisionSettings: Codable, Equatable, Sendable {
    public var distance: Float
    public var maximumCount: Int
    public var maximumBytes: Int
    public var maximumUpdatesPerFrame: Int

    public init(distance: Float = 64, maximumCount: Int = 128, maximumBytes: Int = 32 * 1_024 * 1_024, maximumUpdatesPerFrame: Int = 4) {
        self.distance = distance; self.maximumCount = maximumCount; self.maximumBytes = maximumBytes; self.maximumUpdatesPerFrame = maximumUpdatesPerFrame
    }

    func validate() throws {
        guard distance.isFinite, distance > 0, (0...1_024).contains(maximumCount), maximumBytes >= 0, (1...64).contains(maximumUpdatesPerFrame) else {
            throw TerrainSourceError.invalidConfiguration
        }
    }
}
