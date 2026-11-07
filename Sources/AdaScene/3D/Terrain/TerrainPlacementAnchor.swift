import AdaAssets
import Math

/// Placement rows changed by a sculpt gesture, captured with the height delta for history.
public struct TerrainInstanceCellChange: Sendable {
    public let coordinate: TerrainTileCoordinate
    public let previous: [TerrainRegionInstance]
    public let instances: [TerrainRegionInstance]

    public init(coordinate: TerrainTileCoordinate, previous: [TerrainRegionInstance], instances: [TerrainRegionInstance]) {
        self.coordinate = coordinate; self.previous = previous; self.instances = instances
    }

    public var reversed: Self { .init(coordinate: coordinate, previous: instances, instances: previous) }
}

extension TerrainHeightStorage {
    /// Reprojects only anchors whose height/normal stencil intersects the changed samples.
    /// The staged storage is private to the worker; publication commits height and placement rows together.
    func reprojectAnchors(after changes: [TerrainHeightChange], excluding: Set<TerrainTileCoordinate> = []) throws -> [TerrainInstanceCellChange] {
        guard !changes.isEmpty else {
            return []
        }
        let points = Set(changes.map(\.point))
        let rows = instanceCellSnapshot()
        var cells: Set<TerrainTileCoordinate> = []
        for point in points {
            for z in Self.anchorFloorDiv(point.z - 2, 64)...Self.anchorFloorDiv(point.z + 2, 64) {
                for x in Self.anchorFloorDiv(point.x - 2, 64)...Self.anchorFloorDiv(point.x + 2, 64) {
                    let cell = TerrainTileCoordinate(x: x, z: z)
                    if rows[cell] != nil, !excluding.contains(cell) { cells.insert(cell) }
                }
            }
        }
        var result: [TerrainInstanceCellChange] = []
        var visits = 0
        for cell in cells.sorted() {
            try Task.checkCancellation()
            guard let input = rows[cell] else { continue }
            let regionX = Self.anchorFloorDiv(cell.x, 4) * 256
            let regionZ = Self.anchorFloorDiv(cell.z, 4) * 256
            var records: [TerrainRegionInstance] = []
            records.reserveCapacity(input.records.count)
            for (index, record) in input.records.enumerated() {
                if index % 1_024 == 0 { try Task.checkCancellation() }
                visits += 1
                guard visits <= 262_144 else { throw TerrainHeightBrushError.workBudgetExceeded }
                guard record.flags.contains(.anchored) else { records.append(record); continue }
                let gx = Float(regionX) + record.localPosition.x
                let gz = Float(regionZ) + record.localPosition.z
                let x = Int(gx.rounded(.down)), z = Int(gz.rounded(.down))
                var affected = false
                for pz in (z - 1)...(z + 2) {
                    for px in (x - 1)...(x + 2) where points.contains(.init(x: px, z: pz)) { affected = true }
                }
                guard affected else { records.append(record); continue }
                let point = origin + Vector2(gx, gz) * spacing
                guard let height = heightForAnchor(at: point), let normal = anchorNormal(x: x, z: z, fx: gx - Float(x), fz: gz - Float(z)) else {
                    // History retains the old row when an edited surface no longer supports its anchor.
                    continue
                }
                let rotation =
                    record.flags.contains(.alignToNormal) ? Self.anchorRotation(record.rotation, from: record.anchorNormal, to: normal) : nil
                let updated = try record.updatingAnchor(localHeight: height / spacing + record.anchorOffset, normal: normal, rotation: rotation)
                records.append(updated)
            }
            if records != input.records { result.append(.init(coordinate: cell, previous: input.records, instances: records)) }
        }
        try applyAnchorChanges(result, expectedRevision: revision)
        return result
    }

    func anchorNormal(x: Int, z: Int, fx: Float, fz: Float) -> Vector3? {
        guard let a = normalForBrush(at: .init(x: x, z: z), includeNormalCoverage: true) else {
            return nil
        }
        let b = normalForBrush(at: .init(x: x + 1, z: z), includeNormalCoverage: true) ?? a
        let c = normalForBrush(at: .init(x: x, z: z + 1), includeNormalCoverage: true) ?? a
        let d = normalForBrush(at: .init(x: x + 1, z: z + 1), includeNormalCoverage: true) ?? a
        let value: Vector3
        if fx + fz <= 1 {
            value = a + (b - a) * fx + (c - a) * fz
        } else {
            value = d + (c - d) * (1 - fx) + (b - d) * (1 - fz)
        }
        return value.squaredLength > 0 ? value.normalized : [0, 1, 0]
    }

    private static func anchorRotation(_ rotation: Quat, from previous: Vector3, to normal: Vector3) -> Quat {
        // Recover yaw in a canonical attachment frame, then align against the absolute new normal.
        // Incremental packed-quaternion rotations lose sub-quantum tilt over repeated small edits.
        let oldFrame = anchorFrame(previous)
        let inverse = Quat(x: -oldFrame.x, y: -oldFrame.y, z: -oldFrame.z, w: oldFrame.w)
        let local = anchorMultiply(inverse, rotation)
        let twist = Quat(x: 0, y: local.y, z: 0, w: local.w)
        let yaw = twist.squaredLength > 0 ? twist.normalized : .identity
        return anchorMultiply(anchorFrame(normal), yaw).normalized
    }

    static func anchorFrame(_ normal: Vector3) -> Quat {
        let x = Double(normal.x), y = Double(normal.y), z = Double(normal.z)
        let length = (x * x + y * y + z * z).squareRoot()
        let w = 1 + y / length
        if w <= Double.ulpOfOne {
            return Quat(x: 1, y: 0, z: 0, w: 0)
        }
        return Quat(x: Float(z / length), y: 0, z: Float(-x / length), w: Float(w)).normalized
    }

    static func anchorMultiply(_ lhs: Quat, _ rhs: Quat) -> Quat {
        Quat(
            x: lhs.w * rhs.x + lhs.x * rhs.w + lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.w * rhs.y - lhs.x * rhs.z + lhs.y * rhs.w + lhs.z * rhs.x,
            z: lhs.w * rhs.z + lhs.x * rhs.y - lhs.y * rhs.x + lhs.z * rhs.w,
            w: lhs.w * rhs.w - lhs.x * rhs.x - lhs.y * rhs.y - lhs.z * rhs.z
        )
    }

    private static func anchorFloorDiv(_ value: Int, _ divisor: Int) -> Int {
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }
}
