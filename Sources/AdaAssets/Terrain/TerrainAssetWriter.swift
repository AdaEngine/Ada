import Foundation

#if os(Windows)
    import WinSDK
#elseif canImport(Darwin)
    import Darwin
#elseif os(Android)
    import Android
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Selects complete replacement or an incremental edit of an existing manifest generation.
public enum TerrainRegionSaveMode: Sendable {
    case replaceAll
    /// Retains all untouched references. Removals must match the supplied baseline generation.
    case update(removing: [TerrainRegionReference])
}

public enum TerrainSaveError: LocalizedError {
    case byteBudgetExceeded(Int)
    case tooManyRegions
    case saveInProgress
    case staleManifest
    case meshTerrainRequiresMeshWriter
    case invalidRemoval
    case commitFailed(UInt32)

    public var errorDescription: String? {
        switch self {
        case let .byteBudgetExceeded(limit): "Terrain save exceeds its encoded byte budget of \(limit)"
        case .tooManyRegions: "Terrain save exceeds 16384 region resources"
        case .saveInProgress: "Another terrain save is in progress for this manifest"
        case .staleManifest: "Terrain manifest differs from the supplied baseline generation"
        case .meshTerrainRequiresMeshWriter: "Height and volume saves cannot replace Mesh Terrain. Use the Mesh Terrain editor."
        case .invalidRemoval: "Terrain removal must uniquely match an existing reference and cannot also replace that region"
        case let .commitFailed(code): "Terrain manifest commit failed with system error \(code)"
        }
    }
}

enum TerrainAssetWriter {
    private struct Address: Hashable {
        let x: Int32
        let z: Int32
    }

    #if !WASM
        @concurrent
        static func save(
            _ regions: [TerrainRegionAsset],
            manifest: TerrainManifestAsset,
            destination: URL,
            mode: TerrainRegionSaveMode = .replaceAll,
            volume: TerrainVolumeSave? = nil,
            maximumBytes: Int,
            onProgress: (@Sendable (Int, Int) async -> Void)?
        ) async throws -> TerrainManifestAsset {
            try Task.checkCancellation()
            guard maximumBytes >= 0 else { throw TerrainSaveError.byteBudgetExceeded(maximumBytes) }
            guard regions.count <= 16_384 else { throw TerrainSaveError.tooManyRegions }
            try manifest.validate()
            guard manifest.meshDocumentFileName == nil else { throw TerrainSaveError.meshTerrainRequiresMeshWriter }
            var references: [TerrainRegionReference] = []
            references.reserveCapacity(regions.count)
            var encodedBytes = 0
            // Validate the complete immutable input before creating any filesystem entries.
            for region in regions {
                try Task.checkCancellation()
                try region.validate()
                guard encodedBytes <= maximumBytes - region.encodedByteCount else { throw TerrainSaveError.byteBudgetExceeded(maximumBytes) }
                encodedBytes += region.encodedByteCount
                let name = "height-\(region.x)-\(region.z)-\(UUID().uuidString.lowercased()).atregion"
                references.append(.init(x: region.x, z: region.z, fileName: name))
            }
            // Check duplicate input addresses before attempting to reuse any prior resources.
            try TerrainManifestAsset(
                spacing: manifest.spacing,
                originX: manifest.originX,
                originZ: manifest.originZ,
                heightRegions: references,
                meshPrototypes: manifest.meshPrototypes,
                materials: manifest.materials,
                volumeFileName: manifest.volumeFileName
            )
                .validate()
            let directory = destination.deletingLastPathComponent()
            var previous: [Address: TerrainRegionReference] = [:]
            for ref in manifest.heightRegions { previous[Address(x: ref.x, z: ref.z)] = ref }
            let retained = try retainedReferences(mode: mode, manifest: manifest, replacements: references, previous: previous)
            let baselineMode: TerrainRegionSaveMode
            if case .update = volume?.mode { baselineMode = .update(removing: []) } else { baselineMode = mode }
            try await checkBaseline(mode: baselineMode, manifest: manifest, destination: destination)
            let volumePlan: TerrainVolumeWritePlan?
            if let volume {
                volumePlan = try await TerrainVolumeAssetWriter.plan(volume, manifest: manifest, directory: directory, maximumBytes: maximumBytes - encodedBytes)
                if let volumePlan { encodedBytes += volumePlan.encodedByteCount }
            } else {
                if let name = manifest.volumeFileName { try await TerrainVolumeAssetWriter.validateRetained(name, palette: manifest.materials, directory: directory) }
                volumePlan = nil
            }
            var reused = Array(repeating: false, count: regions.count)
            for index in regions.indices {
                try Task.checkCancellation()
                let region = regions[index]
                guard let ref = previous[Address(x: region.x, z: region.z)] else { continue }
                let file = directory.appendingPathComponent(ref.fileName)
                if try await matches(region, file: file) { references[index] = ref; reused[index] = true }
            }
            let updated = TerrainManifestAsset(
                spacing: manifest.spacing,
                originX: manifest.originX,
                originZ: manifest.originZ,
                heightRegions: retained + references,
                meshPrototypes: manifest.meshPrototypes,
                materials: manifest.materials,
                volumeFileName: volumePlan?.fileName ?? manifest.volumeFileName
            )
            let manifestBytes = try updated.encodedData()
            guard encodedBytes <= maximumBytes - manifestBytes.count else { throw TerrainSaveError.byteBudgetExceeded(maximumBytes) }
            try Task.checkCancellation()

            let fileManager = FileManager.default
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var created: [URL] = []
            var committed = false
            defer {
                if !committed {
                    // These exact files were created by this operation with exclusive creation.
                    for file in created { try? fileManager.removeItem(at: file) }
                }
            }
            let progressTotal = regions.count + (volumePlan?.progressCount ?? 0)
            for (index, region) in regions.enumerated() {
                try Task.checkCancellation()
                if !reused[index] {
                    let file = directory.appendingPathComponent(references[index].fileName)
                    let data = try region.encodedData()
                    try write(data, to: file, created: &created)
                }
                await onProgress?(index + 1, progressTotal)
                try Task.checkCancellation()
            }
            if let volumePlan {
                try await volumePlan.stage(directory: directory, created: &created, progressOffset: regions.count, total: progressTotal, onProgress: onProgress)
            }
            let temporary = directory.appendingPathComponent(".ada-terrain-\(UUID().uuidString).tmp")
            try write(manifestBytes, to: temporary, created: &created)
            try Task.checkCancellation()
            try await checkBaseline(mode: baselineMode, manifest: manifest, destination: destination)
            try Task.checkCancellation()
            try commit(temporary: temporary, destination: destination)
            // No cancellation check after the commit: the returned generation is already published.
            committed = true
            return updated
        }

        private static func retainedReferences(
            mode: TerrainRegionSaveMode,
            manifest: TerrainManifestAsset,
            replacements: [TerrainRegionReference],
            previous: [Address: TerrainRegionReference]
        ) throws -> [TerrainRegionReference] {
            guard case let .update(removing) = mode else {
                return []
            }
            guard removing.count <= 16_384 else { throw TerrainSaveError.tooManyRegions }
            let replaced = Set(replacements.map { Address(x: $0.x, z: $0.z) })
            var removed: Set<Address> = []
            for reference in removing {
                let address = Address(x: reference.x, z: reference.z)
                guard previous[address] == reference, !replaced.contains(address), removed.insert(address).inserted else {
                    throw TerrainSaveError.invalidRemoval
                }
            }
            let retained = manifest.heightRegions.filter {
                let address = Address(x: $0.x, z: $0.z)
                return !replaced.contains(address) && !removed.contains(address)
            }
            guard retained.count <= 16_384 - replacements.count else { throw TerrainSaveError.tooManyRegions }
            return retained
        }

        private static func checkBaseline(mode: TerrainRegionSaveMode, manifest: TerrainManifestAsset, destination: URL) async throws {
            let requiresBaseline: Bool
            if case .update = mode { requiresBaseline = true } else { requiresBaseline = false }
            guard requiresBaseline || FileManager.default.fileExists(atPath: destination.path) else { return }
            let current: TerrainManifestAsset
            do {
                let bytes = try await AssetsManager.readBoundedFile(url: destination, maximumBytes: 4 * 1_024 * 1_024)
                current = try TerrainManifestAsset(data: bytes)
            } catch is CancellationError { throw CancellationError() } catch { throw TerrainSaveError.staleManifest }
            guard current.meshDocumentFileName == nil else { throw TerrainSaveError.meshTerrainRequiresMeshWriter }
            if requiresBaseline {
                guard try current.encodedData() == manifest.encodedData() else { throw TerrainSaveError.staleManifest }
            }
        }

        private static func matches(_ region: TerrainRegionAsset, file: URL) async throws -> Bool {
            guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                info.isRegularFile == true, info.isSymbolicLink != true
            else { return false }
            let expected = try region.encodedData()
            let existing = try? await AssetsManager.readBoundedFile(url: file, maximumBytes: expected.count)
            try Task.checkCancellation()
            guard let existing else {
                return false
            }
            return existing == expected
        }

        static func write(_ data: Data, to url: URL, created: inout [URL]) throws {
            try data.write(to: url, options: .withoutOverwriting)
            created.append(url)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
        }

        private static func commit(temporary: URL, destination: URL) throws {
            #if os(Windows)
                // Both UTF-16 buffers remain alive until the same-directory atomic rename returns.
                let result = unsafe temporary.path.withCString(encodedAs: UTF16.self) { source in
                    unsafe destination.path.withCString(encodedAs: UTF16.self) { target in
                        let moved = unsafe MoveFileExW(source, target, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
                        return (moved, GetLastError())
                    }
                }
                guard result.0 else { throw TerrainSaveError.commitFailed(result.1) }
            #elseif canImport(Darwin) || os(Android) || canImport(Glibc) || canImport(Musl)
                // POSIX rename replaces a same-filesystem destination atomically. Capture errno
                // before either temporary string buffer is released.
                let result = unsafe temporary.path.withCString { source in
                    unsafe destination.path.withCString { target in
                        let status = unsafe rename(source, target)
                        return (status, errno)
                    }
                }
                guard result.0 == 0 else { throw TerrainSaveError.commitFailed(UInt32(result.1)) }
            #else
                throw AssetError.message("Atomic terrain saving is unavailable on this native platform")
            #endif
        }
    #endif
}
