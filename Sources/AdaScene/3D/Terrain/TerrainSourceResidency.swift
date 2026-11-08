import AdaAssets
import Foundation
import Math

struct TerrainRegionOverride: Sendable {
    let pages: [TerrainRegionHeightPage]
    /// Nil retains the source layout; an empty array is an authored removal.
    let tiles: [TerrainRegionTile]?
    let instances: [TerrainRegionInstance]
    let surface: [TerrainRegionSurfaceSample]
    let ruleMasks: [TerrainRegionRuleMaskSample]

    init(
        pages: [TerrainRegionHeightPage],
        tiles: [TerrainRegionTile]?,
        instances: [TerrainRegionInstance],
        surface: [TerrainRegionSurfaceSample] = [],
        ruleMasks: [TerrainRegionRuleMaskSample] = []
    ) {
        self.pages = pages; self.tiles = tiles; self.instances = instances; self.surface = surface; self.ruleMasks = ruleMasks
    }
}

struct TerrainSourceResidency: Sendable {
    var transactionPins: Set<TerrainRegionCoordinate> = []
    let cache: TerrainRegionCache
    let visible: Set<TerrainRegionCoordinate>
    let baseline: [TerrainRegionCoordinate: TerrainRegionAsset]
    let overrides: [TerrainRegionCoordinate: TerrainRegionOverride]
    let layouts: [TerrainRegionCoordinate: [TerrainRegionTile]]
    let heightBudget: Int
    let regionBudget: Int
    var materialMaps: TerrainPreparedMaterialMaps?
    var prototypes: [UInt16: TerrainMeshPrototype] = [:]
    var admittedRevision: UInt64?
    /// Complete baselines held by storage, including empty and normal-only loaded regions.
    var knownRegions: Set<TerrainRegionCoordinate> = []
    var volume: TerrainSourceVolume?
}

struct TerrainResidencyInput: Sendable {
    let storage: TerrainHeightStorage
    let target: TerrainHeightStorage?
    let expectedRevision: UInt64?
    let residency: TerrainSourceResidency?
}

struct TerrainManifestLoadFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension TerrainSourceResidency {
    static func openManifest(at path: String, limits: TerrainRegionCache.Limits = .init()) async throws -> TerrainRegionCache {
        do {
            return try await TerrainRegionCache.open(manifestAt: path, limits: limits)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TerrainManifestLoadFailure(message: error.localizedDescription)
        }
    }

    func pinning(_ coordinates: Set<TerrainRegionCoordinate>) -> Self {
        var value = self
        value.transactionPins = coordinates
        return value
    }

    static func physicsRegions(
        available: Set<TerrainRegionCoordinate>,
        manifest: TerrainManifestAsset,
        interests: TerrainPhysicsInterests,
        padding: Float
    ) -> Set<TerrainRegionCoordinate> {
        if interests.requiresAllRegions {
            return available
        }
        return Set(
            available.filter { coordinate in
                let minX = Double(manifest.originX) + Double(coordinate.x * 256) * Double(manifest.spacing)
                let minZ = Double(manifest.originZ) + Double(coordinate.z * 256) * Double(manifest.spacing)
                let maxX = minX + 256 * Double(manifest.spacing), maxZ = minZ + 256 * Double(manifest.spacing)
                return interests.rectangles.contains { interest in
                    Double(interest.min.x) - Double(padding) <= maxX && Double(interest.max.x) + Double(padding) >= minX
                        && Double(interest.min.y) - Double(padding) <= maxZ && Double(interest.max.y) + Double(padding) >= minZ
                }
            }
        )
    }

    @concurrent
    static func prepare(
        source: Terrain3DSource,
        previous: TerrainSourceResidency?,
        storage: TerrainHeightStorage?,
        focus: TerrainSourceFocus,
        matrix: Transform3D,
        transactionPins: Set<TerrainRegionCoordinate> = [],
        authoringRead: Set<TerrainRegionCoordinate> = []
    ) async throws -> TerrainResidencyInput {
        let baseCache: TerrainRegionCache
        if let previous {
            baseCache = previous.cache
        } else {
            baseCache = try await openManifest(
                at: source.source,
                limits: .init(
                    maximumResidentHeightBytes: source.maximumResidentHeightBytes,
                    maximumResidentRegions: source.maximumResidentRegions
                )
            )
        }
        let manifest = baseCache.manifest
        let declared = Set(manifest.heightRegions.map { TerrainRegionCoordinate(x: Int($0.x), z: Int($0.z)) })
        let available = declared.union(storage?.regionCoordinates ?? []).union(previous.map { Array($0.overrides.keys) } ?? [])
        let visible = try visibleRegions(
            available,
            manifest: manifest,
            radius: source.streamingRadius,
            focus: focus,
            padding: source.physicsPadding,
            inverse: matrix.inverse
        )
        if let previous, let storage, visible == previous.visible, previous.transactionPins == transactionPins,
            previous.heightBudget == source.maximumResidentHeightBytes, previous.regionBudget == source.maximumResidentRegions,
            storage.memoryBudgetBytes == source.maximumResidentHeightBytes, previous.admittedRevision == storage.revision,
            authoringRead.isSubset(of: previous.knownRegions) {
            return .init(storage: storage, target: nil, expectedRevision: nil, residency: previous)
        }
        let target =
            try storage
            ?? TerrainHeightStorage(
                spacing: manifest.spacing,
                origin: [manifest.originX, manifest.originZ],
                memoryBudgetBytes: source.maximumResidentHeightBytes
            )
        let expected = target.revision
        var overrides = previous?.overrides ?? [:]
        var layouts = previous?.layouts ?? [:]
        if let previous, let storage { overrides = try previous.capturedOverrides(storage).overrides }
        var read = Set(overrides.keys).union(transactionPins)
        let seeds = visible.union(authoringRead.filter { declared.contains($0) || overrides[$0] != nil })
        for coordinate in seeds {
            read.insert(coordinate)
            for z in -1...1 {
                for x in -1...1 {
                    let neighbor = TerrainRegionCoordinate(x: coordinate.x + x, z: coordinate.z + z)
                    if declared.contains(neighbor) || overrides[neighbor] != nil { read.insert(neighbor) }
                }
            }
        }
        guard read.count <= source.maximumResidentRegions else { throw TerrainRegionCache.CacheError.regionBudgetExceeded }
        var overrideBytes = 0
        var overrideInstanceBytes = 0
        var overrideSurfaceBytes = 0
        for value in overrides.values {
            let bytes = value.pages.count * 64 * 64 * MemoryLayout<Float>.stride
            guard overrideBytes <= source.maximumResidentHeightBytes - bytes else { throw TerrainRegionCache.CacheError.memoryBudgetExceeded }
            overrideBytes += bytes
            let instanceBytes = value.instances.count * MemoryLayout<TerrainRegionInstance>.stride
            guard overrideInstanceBytes <= target.instanceMemoryBudgetBytes - instanceBytes else {
                throw TerrainRegionCache.CacheError.instanceMemoryBudgetExceeded
            }
            overrideInstanceBytes += instanceBytes
            let surfaceBytes = value.surface.count * MemoryLayout<TerrainRegionSurfaceSample>.stride
                + value.ruleMasks.count * MemoryLayout<TerrainRegionRuleMaskSample>.stride
            guard surfaceBytes <= target.surfaceMemoryBudgetBytes - overrideSurfaceBytes else {
                throw TerrainRegionCache.CacheError.surfaceMemoryBudgetExceeded
            }
            overrideSurfaceBytes += surfaceBytes
        }
        let limits = TerrainRegionCache.Limits(
            maximumResidentHeightBytes: source.maximumResidentHeightBytes - overrideBytes,
            maximumResidentRegions: source.maximumResidentRegions,
            maximumResidentInstanceBytes: target.instanceMemoryBudgetBytes - overrideInstanceBytes,
            maximumResidentSurfaceBytes: target.surfaceMemoryBudgetBytes - overrideSurfaceBytes
        )
        let cache = try await baseCache.fork(limits: limits)
        var regions: [TerrainRegionAsset] = []
        for coordinate in read.sorted() {
            try Task.checkCancellation()
            let value: TerrainRegionAsset
            if let local = overrides[coordinate] {
                value = TerrainRegionAsset(
                    x: Int32(coordinate.x),
                    z: Int32(coordinate.z),
                    tiles: local.tiles ?? layouts[coordinate] ?? [],
                    pages: local.pages,
                    instances: local.instances,
                    surface: local.surface,
                    ruleMasks: local.ruleMasks
                )
            } else {
                let cached = await baseCache.residentValue(at: coordinate)
                let loaded: TerrainRegionAsset?
                if let cached { loaded = try await cache.retain(cached) } else { loaded = try await cache.loadRegion(at: coordinate) }
                guard let loaded else { throw TerrainRegionCache.CacheError.invalidCoordinate }
                value = loaded
                layouts[coordinate] = value.tiles
            }
            regions.append(value)
        }
        let candidate = try target.residencySnapshot(
            regions: regions,
            visible: visible,
            expectedRevision: expected,
            memoryBudgetBytes: source.maximumResidentHeightBytes
        )
        let residency = TerrainSourceResidency(
            cache: cache,
            visible: visible,
            baseline: try export(candidate),
            overrides: overrides,
            layouts: layouts,
            heightBudget: source.maximumResidentHeightBytes,
            regionBudget: source.maximumResidentRegions,
            materialMaps: previous?.materialMaps,
            prototypes: previous?.prototypes ?? [:],
            admittedRevision: candidate.revision,
            knownRegions: read,
            volume: previous?.volume
        ).pinning(transactionPins)
        return .init(storage: candidate, target: target, expectedRevision: expected, residency: residency)
    }

    static func export(_ storage: TerrainHeightStorage) throws -> [TerrainRegionCoordinate: TerrainRegionAsset] {
        let revision = storage.revision
        var result: [TerrainRegionCoordinate: TerrainRegionAsset] = [:]
        for coordinate in storage.resourceCoordinates {
            try Task.checkCancellation()
            if let resource = try storage.regionAsset(at: coordinate) { result[coordinate] = resource }
        }
        guard storage.revision == revision else { throw TerrainHeightStorage.StorageError.staleRevision }
        return result
    }

    private static func visibleRegions(
        _ available: Set<TerrainRegionCoordinate>,
        manifest: TerrainManifestAsset,
        radius: Float?,
        focus: TerrainSourceFocus,
        padding: Float,
        inverse: Transform3D
    ) throws -> Set<TerrainRegionCoordinate> {
        guard let radius, !focus.allCameraRegions, !focus.physics.requiresAllRegions else {
            return available
        }
        let cameras = focus.cameras.compactMap { position -> Vector2? in
            let local = (inverse * Vector4(position, 1)).xyz
            return local.x.isFinite && local.z.isFinite ? Vector2(local.x, local.z) : nil
        }
        guard !cameras.isEmpty || !focus.physics.isEmpty else {
            return available
        }
        let limit = Double(radius) * Double(radius)
        var selected = physicsRegions(available: available, manifest: manifest, interests: focus.physics, padding: padding)
        for coordinate in available {
            try Task.checkCancellation()
            let minX = Double(manifest.originX) + Double(coordinate.x * 256) * Double(manifest.spacing)
            let minZ = Double(manifest.originZ) + Double(coordinate.z * 256) * Double(manifest.spacing)
            let maxX = minX + 256 * Double(manifest.spacing), maxZ = minZ + 256 * Double(manifest.spacing)
            for camera in cameras {
                let dx = max(0, max(minX - Double(camera.x), Double(camera.x) - maxX))
                let dz = max(0, max(minZ - Double(camera.y), Double(camera.y) - maxZ))
                if dx * dx + dz * dz <= limit { selected.insert(coordinate); break }
            }
        }
        return selected
    }
}
