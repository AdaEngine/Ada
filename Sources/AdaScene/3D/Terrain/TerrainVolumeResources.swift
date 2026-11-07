@_spi(Internal) import AdaApp
import AdaAssets
import Foundation

/// Immutable metadata and originating project scope for independently loaded density resources.
public struct TerrainVolumeResources: Sendable {
    public let document: TerrainVolumeDocumentAsset
    private let manifestPath: String
    private let scopeID: UUID?
    private let importLimits: ModelImportLimits
    private let layerIDs: Set<UInt16>
    private let references: [TerrainVolumeBrickCoordinate: TerrainVolumeBrickReference]

    @AssetActor
    static func open(
        documentPath: String,
        manifestPath: String,
        scopeID: UUID?,
        layerIDs: Set<UInt16>,
        importLimits: ModelImportLimits
    ) async throws -> Self {
        try Task.checkCancellation()
        let document = try await AppWorldsExecutionContext.$currentID.withValue(scopeID) {
            try await AssetsManager.loadFresh(TerrainVolumeDocumentAsset.self, at: documentPath)
        }
        for operation in document.operations where operation.isEnabled {
            if let layer = operation.layerID, !layerIDs.contains(layer) {
                throw TerrainVolumeAssetError.malformed("missing active volume material layer")
            }
        }
        var references: [TerrainVolumeBrickCoordinate: TerrainVolumeBrickReference] = [:]
        for reference in document.bricks {
            references[.init(x: reference.x, y: reference.y, z: reference.z)] = reference
        }
        try Task.checkCancellation()
        return Self(document: document, manifestPath: manifestPath, scopeID: scopeID, importLimits: importLimits, layerIDs: layerIDs, references: references)
    }

    /// Loads one enabled static operand in the original project context and prepares its closed solid.
    @concurrent
    public func loadPreparedMesh(
        operationID: UUID,
        maximumBytes: Int = 32 * 1_024 * 1_024,
        maximumValidationWork: Int = 8_388_608
    ) async throws -> TerrainVolumePreparedMesh {
        try Task.checkCancellation()
        guard maximumBytes >= 0 else { throw TerrainVolumeFieldError.invalidConfiguration }
        guard maximumBytes > 0 else { throw TerrainVolumeFieldError.memoryBudgetExceeded }
        guard let operation = document.operations.first(where: { $0.id == operationID && $0.isEnabled }),
            case let .mesh(path, _) = operation.operand else { throw TerrainVolumeFieldError.missingMesh }
        let model = try await readModel(path, maximumBytes: maximumBytes)
        return try TerrainVolumePreparedMesh(operation: operation, model: model, maximumBytes: maximumBytes, maximumValidationWork: maximumValidationWork)
    }

    @AssetActor
    private func readModel(_ relativePath: String, maximumBytes: Int) async throws -> ModelAsset3D {
        let limits = ModelImportLimits(
            maximumEncodedBytes: min(importLimits.maximumEncodedBytes, maximumBytes),
            maximumDecodedBytes: min(importLimits.maximumDecodedBytes, maximumBytes)
        )
        return try await AppWorldsExecutionContext.$currentID.withValue(scopeID) {
            try await ModelImportContext.$limits.withValue(limits) {
                try await AssetsManager.loadFresh(ModelAsset3D.self, at: TerrainRegionCache.resourcePath(relativePath, manifestPath: manifestPath))
            }
        }
    }

    /// Returns a private complete selection or throws without publishing any partial generation.
    /// Limits charge conservative decoded/staging storage, not browser or filesystem caches.
    public func loadBricks(
        at coordinates: [TerrainVolumeBrickCoordinate],
        maximumBytes: Int = 64 * 1_024 * 1_024,
        maximumBricks: Int = 256
    ) async throws -> [TerrainVolumeBrickAsset] {
        try Task.checkCancellation()
        guard (0...1_073_741_824).contains(maximumBytes), (0...4_096).contains(maximumBricks) else { throw TerrainVolumeFieldError.invalidConfiguration }
        guard coordinates.count <= maximumBricks, coordinates.count <= maximumBytes / TerrainVolumeField.brickAllocationBytes else {
            throw TerrainVolumeFieldError.memoryBudgetExceeded
        }
        var selected: [TerrainVolumeBrickReference] = [], seen: Set<TerrainVolumeBrickCoordinate> = []
        for coordinate in coordinates {
            guard let reference = references[coordinate], seen.insert(coordinate).inserted else { throw TerrainVolumeFieldError.invalidCoordinate }
            selected.append(reference)
        }
        return try await read(selected)
    }

    @AssetActor
    private func read(_ selected: [TerrainVolumeBrickReference]) async throws -> [TerrainVolumeBrickAsset] {
        try await AppWorldsExecutionContext.$currentID.withValue(scopeID) {
            var result: [TerrainVolumeBrickAsset] = []
            result.reserveCapacity(selected.count)
            for reference in selected {
                try Task.checkCancellation()
                let path = TerrainRegionCache.resourcePath(reference.fileName, manifestPath: manifestPath)
                let brick = try await AssetsManager.loadFresh(TerrainVolumeBrickAsset.self, at: path)
                guard brick.x == reference.x, brick.y == reference.y, brick.z == reference.z else {
                    throw TerrainVolumeAssetError.malformed("cached volume brick address mismatch")
                }
                for (index, tag) in brick.materialTags.enumerated() where tag != TerrainVolumeBrickAsset.unassignedMaterial {
                    if index.isMultiple(of: 256) { try Task.checkCancellation() }
                    guard layerIDs.contains(UInt16(tag)) else { throw TerrainVolumeAssetError.malformed("missing cached volume material layer") }
                }
                result.append(brick)
            }
            try Task.checkCancellation()
            return result
        }
    }
}
