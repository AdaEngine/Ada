import Foundation

#if !WASM
    struct TerrainVolumeWritePlan: Sendable {
        let fileName: String
        let documentBytes: Data?
        let bricks: [TerrainVolumeBrickAsset]
        let references: [TerrainVolumeBrickReference]
        let reused: [Bool]
        let encodedByteCount: Int
        var progressCount: Int { bricks.count + 1 }

        func stage(
            directory: URL,
            created: inout [URL],
            progressOffset: Int,
            total: Int,
            onProgress: (@Sendable (Int, Int) async -> Void)?
        ) async throws {
            for index in bricks.indices {
                try Task.checkCancellation()
                if !reused[index] {
                    let bytes = try bricks[index].encodedData()
                    try TerrainAssetWriter.write(bytes, to: directory.appendingPathComponent(references[index].fileName), created: &created)
                }
                await onProgress?(progressOffset + index + 1, total)
                try Task.checkCancellation()
            }
            if let documentBytes {
                try TerrainAssetWriter.write(documentBytes, to: directory.appendingPathComponent(fileName), created: &created)
            }
            await onProgress?(progressOffset + progressCount, total)
            try Task.checkCancellation()
        }
    }

    enum TerrainVolumeAssetWriter {
        private struct Address: Hashable {
            let x: Int32
            let y: Int32
            let z: Int32
            init(_ brick: TerrainVolumeBrickAsset) { x = brick.x; y = brick.y; z = brick.z }
            init(_ reference: TerrainVolumeBrickReference) { x = reference.x; y = reference.y; z = reference.z }
        }

        static func plan(_ request: TerrainVolumeSave, manifest: TerrainManifestAsset, directory: URL, maximumBytes: Int) async throws -> TerrainVolumeWritePlan {
            try Task.checkCancellation()
            try request.document.validate()
            guard maximumBytes >= 0 else { throw TerrainSaveError.byteBudgetExceeded(maximumBytes) }
            guard request.bricks.count <= TerrainVolumeDocumentAsset.maximumBricks else { throw TerrainSaveError.tooManyRegions }
            let brickBytes = TerrainVolumeBrickAsset.maximumEncodedBytes ?? 0
            guard request.bricks.count <= maximumBytes / brickBytes else { throw TerrainSaveError.byteBudgetExceeded(maximumBytes) }
            let encodedBricks = request.bricks.count * brickBytes
            var baseline: TerrainVolumeDocumentAsset?
            do {
                if let name = manifest.volumeFileName {
                    baseline = try await readDocument(name, directory: directory)
                } else { baseline = nil }
            } catch is CancellationError { throw CancellationError() } catch {
                if case .replaceAll = request.mode { baseline = nil } else { throw TerrainSaveError.staleManifest }
            }
            var previous: [Address: TerrainVolumeBrickReference] = [:]
            if let baseline { for reference in baseline.bricks { previous[Address(reference)] = reference } }
            var replacements: [TerrainVolumeBrickReference] = [], addresses: Set<Address> = []
            let layers = manifest.materials.map { Set($0.layers.map(\.id)) }
            try validateOperations(request.document, palette: manifest.materials)
            for brick in request.bricks {
                try Task.checkCancellation()
                try brick.validate()
                guard addresses.insert(Address(brick)).inserted else { throw TerrainVolumeAssetError.malformed("duplicate supplied volume brick") }
                for (index, tag) in brick.materialTags.enumerated() where tag != TerrainVolumeBrickAsset.unassignedMaterial {
                    if index.isMultiple(of: 256) { try Task.checkCancellation() }
                    guard layers?.contains(UInt16(tag)) == true else { throw TerrainVolumeAssetError.malformed("missing cached volume material layer") }
                }
                let name = "volume-\(brick.x)-\(brick.y)-\(brick.z)-\(UUID().uuidString.lowercased()).atvolbrick"
                replacements.append(.init(x: brick.x, y: brick.y, z: brick.z, fileName: name))
            }
            let retained = try retainedReferences(request, baseline: baseline, replacing: addresses, previous: previous)
            try await validateReferences(retained, palette: manifest.materials, directory: directory)
            if let baseline, !retained.isEmpty, (baseline.cellSize != request.document.cellSize || baseline.origin != request.document.origin) {
                throw TerrainVolumeAssetError.malformed("changing the volume lattice requires replacing its cached bricks")
            }
            var reused = [Bool](repeating: false, count: request.bricks.count)
            for index in request.bricks.indices {
                let brick = request.bricks[index]
                if let reference = previous[Address(brick)], try await matches(brick, file: directory.appendingPathComponent(reference.fileName)) {
                    replacements[index] = reference; reused[index] = true
                }
            }
            let canonical = (retained + replacements).sorted { ($0.z, $0.y, $0.x) < ($1.z, $1.y, $1.x) }
            let updated = TerrainVolumeDocumentAsset(
                cellSize: request.document.cellSize,
                origin: request.document.origin,
                operations: request.document.operations,
                bricks: canonical
            )
            let bytes = try updated.encodedData()
            guard bytes.count <= maximumBytes - encodedBricks else { throw TerrainSaveError.byteBudgetExceeded(maximumBytes) }
            let count = encodedBricks + bytes.count
            if let baseline, let name = manifest.volumeFileName, try baseline.encodedData() == bytes {
                return .init(fileName: name, documentBytes: nil, bricks: request.bricks, references: replacements, reused: reused, encodedByteCount: count)
            }
            return .init(
                fileName: "volume-\(UUID().uuidString.lowercased()).atvolume",
                documentBytes: bytes,
                bricks: request.bricks,
                references: replacements,
                reused: reused,
                encodedByteCount: count
            )
        }

        static func validateRetained(_ name: String, palette: TerrainMaterialPalette?, directory: URL) async throws {
            let document = try await readDocument(name, directory: directory)
            try validateOperations(document, palette: palette)
            try await validateReferences(document.bricks, palette: palette, directory: directory)
        }

        private static func validateOperations(_ document: TerrainVolumeDocumentAsset, palette: TerrainMaterialPalette?) throws {
            let layers = Set(palette?.layers.map(\.id) ?? [])
            for operation in document.operations where operation.isEnabled {
                try Task.checkCancellation()
                if let layer = operation.layerID, !layers.contains(layer) {
                    throw TerrainVolumeAssetError.malformed("missing active volume material layer")
                }
            }
        }

        private static func validateReferences(_ references: [TerrainVolumeBrickReference], palette: TerrainMaterialPalette?, directory: URL) async throws {
            let layers = Set(palette?.layers.map(\.id) ?? [])
            for reference in references {
                try Task.checkCancellation()
                let file = directory.appendingPathComponent(reference.fileName)
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true, info.fileSize == TerrainVolumeBrickAsset.maximumEncodedBytes else {
                    throw TerrainVolumeAssetError.malformed("missing or incomplete cached volume brick: \(reference.fileName)")
                }
                // Retain only one decoded brick at a time; its codec bounds bytes before allocation.
                let bytes = try await AssetsManager.readBoundedFile(url: file, maximumBytes: TerrainVolumeBrickAsset.maximumEncodedBytes ?? 0)
                let brick = try TerrainVolumeBrickAsset(data: bytes)
                guard brick.x == reference.x, brick.y == reference.y, brick.z == reference.z else {
                    throw TerrainVolumeAssetError.malformed("cached volume brick address mismatch")
                }
                for (index, tag) in brick.materialTags.enumerated() where tag != TerrainVolumeBrickAsset.unassignedMaterial {
                    if index.isMultiple(of: 256) { try Task.checkCancellation() }
                    guard layers.contains(UInt16(tag)) else { throw TerrainVolumeAssetError.malformed("missing retained volume material layer") }
                }
            }
        }

        private static func retainedReferences(
            _ request: TerrainVolumeSave,
            baseline: TerrainVolumeDocumentAsset?,
            replacing: Set<Address>,
            previous: [Address: TerrainVolumeBrickReference]
        ) throws -> [TerrainVolumeBrickReference] {
            guard case let .update(removing) = request.mode else {
                return []
            }
            guard let baseline, baseline.bricks == request.document.bricks else { throw TerrainSaveError.staleManifest }
            guard removing.count <= TerrainVolumeDocumentAsset.maximumBricks else { throw TerrainSaveError.tooManyRegions }
            var removed: Set<Address> = []
            for reference in removing {
                let address = Address(reference)
                guard previous[address] == reference, !replacing.contains(address), removed.insert(address).inserted else { throw TerrainSaveError.invalidRemoval }
            }
            let retained = baseline.bricks.filter { !replacing.contains(Address($0)) && !removed.contains(Address($0)) }
            guard retained.count <= TerrainVolumeDocumentAsset.maximumBricks - request.bricks.count else { throw TerrainSaveError.tooManyRegions }
            return retained
        }

        private static func readDocument(_ name: String, directory: URL) async throws -> TerrainVolumeDocumentAsset {
            let data = try await AssetsManager.readBoundedFile(url: directory.appendingPathComponent(name), maximumBytes: TerrainVolumeDocumentAsset.maximumEncodedBytes ?? 0)
            return try TerrainVolumeDocumentAsset(data: data)
        }

        private static func matches(_ brick: TerrainVolumeBrickAsset, file: URL) async throws -> Bool {
            guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                info.isRegularFile == true, info.isSymbolicLink != true else { return false }
            let expected = try brick.encodedData()
            let existing = try? await AssetsManager.readBoundedFile(url: file, maximumBytes: expected.count)
            try Task.checkCancellation()
            return existing == expected
        }
    }
#endif
