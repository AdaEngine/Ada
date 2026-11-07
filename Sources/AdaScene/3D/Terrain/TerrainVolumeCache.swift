import AdaAssets
import Foundation

/// Signed address of a canonical 32-cell density brick.
public struct TerrainVolumeBrickCoordinate: Codable, Hashable, Comparable, Sendable {
    public let x: Int32
    public let y: Int32
    public let z: Int32

    public init(x: Int32, y: Int32, z: Int32) { self.x = x; self.y = y; self.z = z }
    public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.z, lhs.y, lhs.x) < (rhs.z, rhs.y, rhs.x) }
}

/// Immutable sparse worker generation. Prepare a replacement before publishing any geometry.
public struct TerrainVolumeCache: Sendable {
    private struct Brick: Sendable {
        let generation = UUID()
        let asset: TerrainVolumeBrickAsset
        let dependency: TerrainVolumeBrickDependency
    }

    public let maximumBytes: Int
    public let maximumBricks: Int
    private var bricks: [TerrainVolumeBrickCoordinate: Brick] = [:]
    private var built = 0
    private var reused = 0
    private var evicted = 0
    public var coordinates: [TerrainVolumeBrickCoordinate] { bricks.keys.sorted() }
    /// Conservative byte charge for this generation, including bounded dependency metadata.
    public var residentBytes: Int { bricks.count * TerrainVolumeField.brickAllocationBytes }
    public var builtBrickCount: Int { built }
    public var reusedBrickCount: Int { reused }
    public var evictedBrickCount: Int { evicted }

    public init(maximumBytes: Int = 64 * 1_024 * 1_024, maximumBricks: Int = 256) throws {
        guard (0...1_073_741_824).contains(maximumBytes), (0...4_096).contains(maximumBricks) else { throw TerrainVolumeFieldError.invalidConfiguration }
        self.maximumBytes = maximumBytes; self.maximumBricks = maximumBricks
    }

    public func brick(at coordinate: TerrainVolumeBrickCoordinate) -> TerrainVolumeBrickAsset? { bricks[coordinate]?.asset }
    public func brickGeneration(at coordinate: TerrainVolumeBrickCoordinate) -> UUID? { bricks[coordinate]?.generation }

    /// Requests/pins bound residency; one shared work allowance covers all regenerated bricks.
    public func preparing(
        field: TerrainVolumeField,
        required: [TerrainVolumeBrickCoordinate],
        pinned: Set<TerrainVolumeBrickCoordinate> = [],
        maximumWork: Int = 268_435_456
    ) throws -> Self {
        try Task.checkCancellation()
        guard required.count <= maximumBricks, pinned.count <= maximumBricks else { throw TerrainVolumeFieldError.memoryBudgetExceeded }
        var requested: Set<TerrainVolumeBrickCoordinate> = []
        for coordinate in required {
            guard requested.insert(coordinate).inserted else { throw TerrainVolumeFieldError.invalidCoordinate }
        }
        requested.formUnion(pinned)
        // Divide before multiplying, including on 32-bit WASM.
        guard requested.count <= maximumBricks, requested.count <= maximumBytes / TerrainVolumeField.brickAllocationBytes else {
            throw TerrainVolumeFieldError.memoryBudgetExceeded
        }
        var budget = try TerrainVolumeFieldWork(maximumWork)
        var next: [TerrainVolumeBrickCoordinate: Brick] = [:]
        var built = 0, reused = 0
        for coordinate in requested.sorted() {
            let dependency = try field.cacheDependency(at: coordinate, budget: &budget)
            if let previous = bricks[coordinate], previous.dependency == dependency {
                next[coordinate] = previous; reused += 1
            } else {
                let asset = try field.buildBrick(x: coordinate.x, y: coordinate.y, z: coordinate.z, maximumBytes: TerrainVolumeField.brickAllocationBytes, budget: &budget)
                next[coordinate] = .init(asset: asset, dependency: dependency); built += 1
            }
        }
        try Task.checkCancellation()
        var result = self
        result.bricks = next; result.built = built; result.reused = reused
        result.evicted = bricks.keys.reduce(into: 0) { if !requested.contains($1) { $0 += 1 } }
        return result
    }
}
