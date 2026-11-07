@_spi(Internal) import AdaApp
import AdaAssets
import AdaRender
import Foundation

/// Bounded region residency for one immutable terrain manifest generation.
public actor TerrainRegionCache {
    public struct Limits: Codable, Equatable, Sendable {
        public var maximumResidentHeightBytes: Int
        public var maximumResidentRegions: Int
        public var maximumConcurrentLoads: Int
        public var maximumResidentInstanceBytes: Int
        public var maximumResidentSurfaceBytes: Int

        public init(
            maximumResidentHeightBytes: Int = 64 * 1_024 * 1_024,
            maximumResidentRegions: Int = 128,
            maximumConcurrentLoads: Int = 4,
            maximumResidentInstanceBytes: Int = 16 * 1_024 * 1_024,
            maximumResidentSurfaceBytes: Int = 32 * 1_024 * 1_024
        ) {
            self.maximumResidentHeightBytes = maximumResidentHeightBytes
            self.maximumResidentRegions = maximumResidentRegions
            self.maximumConcurrentLoads = maximumConcurrentLoads
            self.maximumResidentInstanceBytes = maximumResidentInstanceBytes
            self.maximumResidentSurfaceBytes = maximumResidentSurfaceBytes
        }

        private enum CodingKeys: CodingKey {
            case maximumResidentHeightBytes, maximumResidentRegions, maximumConcurrentLoads, maximumResidentInstanceBytes, maximumResidentSurfaceBytes
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                maximumResidentHeightBytes: try values.decode(Int.self, forKey: .maximumResidentHeightBytes),
                maximumResidentRegions: try values.decode(Int.self, forKey: .maximumResidentRegions),
                maximumConcurrentLoads: try values.decode(Int.self, forKey: .maximumConcurrentLoads),
                maximumResidentInstanceBytes: try values.decodeIfPresent(Int.self, forKey: .maximumResidentInstanceBytes) ?? 16 * 1_024 * 1_024,
                maximumResidentSurfaceBytes: try values.decodeIfPresent(Int.self, forKey: .maximumResidentSurfaceBytes) ?? 32 * 1_024 * 1_024
            )
        }

        func validate() throws {
            guard maximumResidentHeightBytes >= 0, maximumResidentInstanceBytes >= 0, maximumResidentSurfaceBytes >= 0,
                (1...16_384).contains(maximumResidentRegions), (1...16).contains(maximumConcurrentLoads)
            else {
                throw CacheError.invalidLimits
            }
        }
    }

    public struct Statistics: Sendable {
        public let residentRegions: Int
        public let residentHeightBytes: Int
        public let inFlightLoads: Int
        public let residentInstanceBytes: Int
        public let residentSurfaceBytes: Int
    }

    public enum PinReason: Hashable, Sendable { case dirty, selected, transaction, physics }

    public enum CacheError: LocalizedError {
        case invalidLimits
        case invalidCoordinate
        case memoryBudgetExceeded
        case instanceMemoryBudgetExceeded
        case surfaceMemoryBudgetExceeded
        case missingPaintLayer(UInt16)
        case regionBudgetExceeded
        case loadLimitReached
        case mismatchedRegion

        public var errorDescription: String? {
            switch self {
            case .invalidLimits: "Invalid terrain residency limits"
            case .invalidCoordinate: "Invalid terrain region address"
            case .memoryBudgetExceeded: "Terrain resident height-page budget exceeded"
            case .instanceMemoryBudgetExceeded: "Terrain resident placement-record budget exceeded"
            case .surfaceMemoryBudgetExceeded: "Terrain resident surface-record budget exceeded"
            case let .missingPaintLayer(id): "Painted terrain requires a material palette containing layer \(id)"
            case .regionBudgetExceeded: "Terrain resident region count exceeded"
            case .loadLimitReached: "Terrain concurrent region load limit reached"
            case .mismatchedRegion: "Terrain region payload address does not match its manifest reference"
            }
        }
    }

    public let manifest: TerrainManifestAsset
    public let limits: Limits
    private let sourcePath: String
    private let scopeID: UUID?
    private let prototypeImportLimits: ModelImportLimits
    private let paintLayerIDs: Set<UInt16>
    private let references: [TerrainRegionCoordinate: TerrainRegionReference]
    private var pins: [TerrainRegionCoordinate: Set<PinReason>] = [:]
    private var resident: [TerrainRegionCoordinate: TerrainRegionAsset] = [:]
    private var residentBytes = 0
    private var residentInstanceBytes = 0
    private var residentSurfaceBytes = 0
    private var activeLoads = 0
    private static let heightPageBytes = 64 * 64 * MemoryLayout<Float>.stride

    @AssetActor
    public static func open(manifestAt path: String, limits: Limits = .init()) async throws -> TerrainRegionCache {
        let scopeID = AppWorldsExecutionContext.currentID
        let prototypeImportLimits = ModelImportContext.limits ?? .init()
        guard prototypeImportLimits.maximumEncodedBytes > 0, prototypeImportLimits.maximumDecodedBytes > 0 else { throw ModelImportLimitError.invalidLimits }
        try limits.validate()
        guard !path.isEmpty else { throw AssetError.message("Terrain manifest path is empty") }
        if path.hasPrefix("file://"), URL(string: path)?.isFileURL != true { throw AssetError.message("Invalid terrain manifest file URL") }
        let manifest = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: path)
        return try TerrainRegionCache(manifest: manifest, sourcePath: path, scopeID: scopeID, limits: limits, prototypeImportLimits: prototypeImportLimits)
    }

    private init(manifest: TerrainManifestAsset, sourcePath: String, scopeID: UUID?, limits: Limits, prototypeImportLimits: ModelImportLimits) throws {
        try manifest.validate()
        self.manifest = manifest
        paintLayerIDs = Set(manifest.materials?.layers.map(\.id) ?? [])
        self.sourcePath = sourcePath
        self.scopeID = scopeID
        self.prototypeImportLimits = prototypeImportLimits
        self.limits = limits
        var references: [TerrainRegionCoordinate: TerrainRegionReference] = [:]
        for ref in manifest.heightRegions { references[.init(x: Int(ref.x), z: Int(ref.z))] = ref }
        self.references = references
    }

    public var statistics: Statistics {
        .init(
            residentRegions: resident.count,
            residentHeightBytes: residentBytes,
            inFlightLoads: activeLoads,
            residentInstanceBytes: residentInstanceBytes,
            residentSurfaceBytes: residentSurfaceBytes
        )
    }

    /// Starts bounded staging residency under the same immutable manifest and originating asset scope.
    func fork(limits: Limits) throws -> TerrainRegionCache {
        try limits.validate()
        return try TerrainRegionCache(manifest: manifest, sourcePath: sourcePath, scopeID: scopeID, limits: limits, prototypeImportLimits: prototypeImportLimits)
    }

    /// Writes in the asset scope that opened this immutable generation, then creates its next reader.
    nonisolated func saveChanges(
        _ regions: [TerrainRegionAsset],
        removing: [TerrainRegionReference],
        maximumBytes: Int,
        onProgress: (@Sendable (Int, Int) async -> Void)?
    ) async throws -> TerrainRegionCache {
        let updated = try await Self.write(
            regions,
            removing: removing,
            manifest: manifest,
            path: sourcePath,
            scopeID: scopeID,
            maximumBytes: maximumBytes,
            onProgress: onProgress
        )
        // The writer validated this same immutable manifest before committing it. Construction
        // performs the identical deterministic validation; no filesystem operation follows commit.
        return try TerrainRegionCache(manifest: updated, sourcePath: sourcePath, scopeID: scopeID, limits: limits, prototypeImportLimits: prototypeImportLimits)
    }

    @AssetActor
    private static func write(
        _ regions: [TerrainRegionAsset],
        removing: [TerrainRegionReference],
        manifest: TerrainManifestAsset,
        path: String,
        scopeID: UUID?,
        maximumBytes: Int,
        onProgress: (@Sendable (Int, Int) async -> Void)?
    ) async throws -> TerrainManifestAsset {
        try await AppWorldsExecutionContext.$currentID.withValue(scopeID) {
            try await AssetsManager.saveTerrainRegions(
                regions,
                manifest: manifest,
                at: path,
                mode: .update(removing: removing),
                maximumStagedBytes: maximumBytes,
                onProgress: onProgress
            )
        }
    }

    /// Opens only operation metadata; density bricks remain independently requested.
    public func loadVolumeResources() async throws -> TerrainVolumeResources? {
        guard let name = manifest.volumeFileName else {
            return nil
        }
        return try await TerrainVolumeResources.open(
            documentPath: Self.resourcePath(name, manifestPath: sourcePath),
            manifestPath: sourcePath,
            scopeID: scopeID,
            layerIDs: paintLayerIDs,
            importLimits: prototypeImportLimits
        )
    }

    func loadPrototype(_ reference: TerrainMeshPrototypeReference) async throws -> TerrainMeshPrototype {
        try Task.checkCancellation()
        let prototype = try await Self.readPrototype(reference, manifestPath: sourcePath, scopeID: scopeID, importLimits: prototypeImportLimits)
        try Task.checkCancellation()
        return prototype
    }

    @AssetActor
    private static func readPrototype(
        _ reference: TerrainMeshPrototypeReference,
        manifestPath: String,
        scopeID: UUID?,
        importLimits: ModelImportLimits
    ) async throws -> TerrainMeshPrototype {
        try await AppWorldsExecutionContext.$currentID.withValue(scopeID) {
            try await ModelImportContext.$limits.withValue(importLimits) {
                let model = try await AssetsManager.loadFresh(ModelAsset3D.self, at: resourcePath(reference.assetPath, manifestPath: manifestPath))
                return try TerrainMeshPrototype(model: model, scene: reference.scene)
            }
        }
    }

    func loadMeshTerrainMaterialModels(_ paths: Set<String>, maximumBytes: Int) async throws -> (models: [String: [Material]], bytes: Int) {
        guard paths.count <= 32 else { throw TerrainSourceError.meshBudgetExceeded }
        var remaining = maximumBytes, models: [String: [Material]] = [:]
        for path in paths.sorted() {
            try Task.checkCancellation()
            let model = try await Self.readMeshTerrainMaterialModel(path, scopeID: scopeID, limits: .init(
                maximumEncodedBytes: min(remaining, prototypeImportLimits.maximumEncodedBytes),
                maximumDecodedBytes: min(remaining, prototypeImportLimits.maximumDecodedBytes)
            ))
            guard model.bytes <= remaining else { throw TerrainSourceError.meshBudgetExceeded }
            remaining -= model.bytes
            models[path] = model.materials
        }
        return (models, maximumBytes - remaining)
    }

    @AssetActor
    private static func readMeshTerrainMaterialModel(_ path: String, scopeID: UUID?, limits: ModelImportLimits) async throws -> MeshTerrainMaterialModelAsset {
        guard limits.maximumEncodedBytes > 0, limits.maximumDecodedBytes > 0 else { throw TerrainSourceError.meshBudgetExceeded }
        return try await AppWorldsExecutionContext.$currentID.withValue(scopeID) {
            try await ModelImportContext.$limits.withValue(limits) {
                try await AssetsManager.loadFresh(MeshTerrainMaterialModelAsset.self, at: path)
            }
        }
    }

    func loadMaterialImage(_ path: String, encodedLimit: Int) async throws -> TerrainMaterialImageAsset {
        try await Self.readMaterialImage(path, manifestPath: sourcePath, scopeID: scopeID, encodedLimit: encodedLimit)
    }

    @AssetActor
    private static func readMaterialImage(_ path: String, manifestPath: String, scopeID: UUID?, encodedLimit: Int) async throws -> TerrainMaterialImageAsset {
        guard encodedLimit > 0 else { throw ModelImportLimitError.encodedBudgetExceeded }
        return try await AppWorldsExecutionContext.$currentID.withValue(scopeID) {
            try await ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: encodedLimit)) {
                try await AssetsManager.loadFresh(TerrainMaterialImageAsset.self, at: resourcePath(path, manifestPath: manifestPath))
            }
        }
    }

    static func resourcePath(_ name: String, manifestPath: String) -> String {
        if manifestPath.hasPrefix("file://"), let url = URL(string: manifestPath) {
            return url.deletingLastPathComponent().appendingPathComponent(name).absoluteString
        }
        if let separator = manifestPath.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            return String(manifestPath[...separator]) + name
        }
        return name
    }

    func residentValue(at coordinate: TerrainRegionCoordinate) -> TerrainRegionAsset? { resident[coordinate] }

    func retain(_ region: TerrainRegionAsset) throws -> TerrainRegionAsset {
        try region.validate()
        let coordinate = TerrainRegionCoordinate(x: Int(region.x), z: Int(region.z))
        guard let reference = references[coordinate] else { throw CacheError.invalidCoordinate }
        return try store(region, reference: reference, at: coordinate)
    }

    /// Returns nil for a coordinate absent from the manifest; a declared but invalid file throws.
    public func loadRegion(at coordinate: TerrainRegionCoordinate) async throws -> TerrainRegionAsset? {
        try Self.validate(coordinate)
        try Task.checkCancellation()
        if let value = resident[coordinate] {
            return value
        }
        guard let ref = references[coordinate] else {
            return nil
        }
        guard activeLoads < limits.maximumConcurrentLoads else { throw CacheError.loadLimitReached }
        activeLoads += 1
        defer { activeLoads -= 1 }
        let value: TerrainRegionAsset
        do {
            value = try await Self.read(ref, manifestPath: sourcePath, scopeID: scopeID)
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        return try store(value, reference: ref, at: coordinate)
    }

    private func store(_ value: TerrainRegionAsset, reference ref: TerrainRegionReference, at coordinate: TerrainRegionCoordinate) throws -> TerrainRegionAsset {
        guard value.x == ref.x, value.z == ref.z else { throw CacheError.mismatchedRegion }
        // Another request may have published this immutable coordinate while the read was suspended.
        if let current = resident[coordinate] {
            return current
        }
        guard resident.count < limits.maximumResidentRegions else { throw CacheError.regionBudgetExceeded }
        let bytes = value.pages.count * Self.heightPageBytes
        guard residentBytes <= limits.maximumResidentHeightBytes - bytes else { throw CacheError.memoryBudgetExceeded }
        let instanceBytes = value.instances.count * MemoryLayout<TerrainRegionInstance>.stride
        guard residentInstanceBytes <= limits.maximumResidentInstanceBytes - instanceBytes else { throw CacheError.instanceMemoryBudgetExceeded }
        let surfaceBytes = Self.surfaceBytes(value)
        guard residentSurfaceBytes <= limits.maximumResidentSurfaceBytes - surfaceBytes else { throw CacheError.surfaceMemoryBudgetExceeded }
        // Validate every admitted record, including data-only/normal-halo regions. Cached reuse does not rescan.
        for (index, sample) in value.surface.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            guard sample.overrideStrength > 0 else { continue }
            for channel in 0..<4 where sample.weights[channel] > 0 {
                let id = sample.layerIDs[channel]
                guard paintLayerIDs.contains(id) else { throw CacheError.missingPaintLayer(id) }
            }
        }
        resident[coordinate] = value
        residentBytes += bytes
        residentInstanceBytes += instanceBytes
        residentSurfaceBytes += surfaceBytes
        return value
    }

    public func pin(_ coordinate: TerrainRegionCoordinate, reason: PinReason) throws {
        try Self.validate(coordinate)
        guard references[coordinate] != nil else { throw CacheError.invalidCoordinate }
        pins[coordinate, default: []].insert(reason)
    }

    public func unpin(_ coordinate: TerrainRegionCoordinate, reason: PinReason) {
        pins[coordinate]?.remove(reason)
        if pins[coordinate]?.isEmpty == true { pins.removeValue(forKey: coordinate) }
    }

    /// Explicitly releases an unpinned region. Pin reasons are independent of one another.
    @discardableResult
    public func evictRegion(at coordinate: TerrainRegionCoordinate) -> Bool {
        guard pins[coordinate]?.isEmpty != false, let value = resident.removeValue(forKey: coordinate) else {
            return false
        }
        residentBytes -= value.pages.count * Self.heightPageBytes
        residentInstanceBytes -= value.instances.count * MemoryLayout<TerrainRegionInstance>.stride
        residentSurfaceBytes -= Self.surfaceBytes(value)
        return true
    }

    private static func surfaceBytes(_ region: TerrainRegionAsset) -> Int {
        region.surface.count * MemoryLayout<TerrainRegionSurfaceSample>.stride + region.ruleMasks.count * MemoryLayout<TerrainRegionRuleMaskSample>.stride
    }

    private static func validate(_ coordinate: TerrainRegionCoordinate) throws {
        guard (-4_096...4_096).contains(coordinate.x), (-4_096...4_096).contains(coordinate.z) else { throw CacheError.invalidCoordinate }
    }

    @AssetActor
    private static func read(_ ref: TerrainRegionReference, manifestPath: String, scopeID: UUID?) async throws -> TerrainRegionAsset {
        let path = resourcePath(ref.fileName, manifestPath: manifestPath)
        // Actor calls inherit the requesting task's locals. Region paths belong to the
        // world that opened this manifest, even when another world requests cached data.
        return try await AppWorldsExecutionContext.$currentID.withValue(scopeID) {
            try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: path)
        }
    }
}
