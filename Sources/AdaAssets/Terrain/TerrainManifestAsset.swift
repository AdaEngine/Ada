import Foundation

public enum TerrainManifestError: LocalizedError {
    case malformed(String)
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case let .malformed(reason): "Invalid terrain manifest: \(reason)"
        case let .unsupportedVersion(version): "Unsupported terrain manifest version: \(version)"
        }
    }
}

/// A canonical region payload in the same asset directory as its manifest.
public struct TerrainRegionReference: Codable, Hashable, Sendable {
    public let x: Int32
    public let z: Int32
    public let fileName: String

    public init(x: Int32, z: Int32, fileName: String) { self.x = x; self.z = z; self.fileName = fileName }
}

/// Portable terrain layout, static model palette and independently addressable region resources.
public struct TerrainManifestAsset: Asset {
    public static let maximumEncodedBytes: Int? = 4 * 1_024 * 1_024
    public var assetMetaInfo: AssetMetaInfo?
    public let spacing: Float
    public let originX: Float
    public let originZ: Float
    public let heightRegions: [TerrainRegionReference]
    public let meshPrototypes: [TerrainMeshPrototypeReference]
    public let materials: TerrainMaterialPalette?
    /// Optional immutable operation/cache document in the manifest directory.
    public let volumeFileName: String?
    /// Version 5 triangle-surface document. Mutually exclusive with height/volume payloads.
    public let meshDocumentFileName: String?

    private static let maximumRegions = 16_384

    private struct Address: Hashable {
        let x: Int32
        let z: Int32
    }

    private struct References {
        var addresses: Set<Address> = []
        var names: Set<String> = []

        mutating func validate(_ region: TerrainRegionReference) throws {
            try TerrainManifestAsset.validateReference(region)
            guard addresses.insert(Address(x: region.x, z: region.z)).inserted,
                names.insert(region.fileName.lowercased()).inserted
            else { throw TerrainManifestError.malformed("duplicate region reference") }
        }
    }

    private struct Payload: Codable {
        var version: Int
        var spacing: Float
        var originX: Float
        var originZ: Float
        var heightRegions: [TerrainRegionReference]
        var meshPrototypes: [TerrainMeshPrototypeReference]
        var materials: TerrainMaterialPalette?
        var volumeFileName: String?
        var meshDocumentFileName: String?

        enum CodingKeys: CodingKey { case version, spacing, originX, originZ, heightRegions, meshPrototypes, materials, volumeFileName, meshDocumentFileName }

        init(
            version: Int,
            spacing: Float,
            originX: Float,
            originZ: Float,
            heightRegions: [TerrainRegionReference],
            meshPrototypes: [TerrainMeshPrototypeReference],
            materials: TerrainMaterialPalette?,
            volumeFileName: String?,
            meshDocumentFileName: String?
        ) {
            self.version = version; self.spacing = spacing; self.originX = originX; self.originZ = originZ; self.heightRegions = heightRegions; self.meshPrototypes = meshPrototypes
            self.materials = materials; self.volumeFileName = volumeFileName
            self.meshDocumentFileName = meshDocumentFileName
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(spacing, forKey: .spacing)
            try container.encode(originX, forKey: .originX)
            try container.encode(originZ, forKey: .originZ)
            try container.encode(heightRegions, forKey: .heightRegions)
            if !meshPrototypes.isEmpty { try container.encode(meshPrototypes, forKey: .meshPrototypes) }
            try container.encodeIfPresent(materials, forKey: .materials)
            try container.encodeIfPresent(volumeFileName, forKey: .volumeFileName)
            try container.encodeIfPresent(meshDocumentFileName, forKey: .meshDocumentFileName)
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            guard (1...5).contains(version) else { throw TerrainManifestError.unsupportedVersion(version) }
            meshDocumentFileName = try container.decodeIfPresent(String.self, forKey: .meshDocumentFileName)
            if let name = meshDocumentFileName {
                guard version == 5 else { throw TerrainManifestError.malformed("mesh surface document requires version 5") }
                try TerrainManifestAsset.validateMeshReference(name)
            } else if version == 5 { throw TerrainManifestError.malformed("version 5 requires a mesh surface document") }
            spacing = try container.decode(Float.self, forKey: .spacing)
            originX = try container.decode(Float.self, forKey: .originX)
            originZ = try container.decode(Float.self, forKey: .originZ)
            try TerrainManifestAsset.validateConfiguration(spacing: spacing, originX: originX, originZ: originZ)
            if container.contains(.volumeFileName) {
                guard version == 4 else { throw TerrainManifestError.malformed("volume document requires version 4") }
                let name = try container.decode(String.self, forKey: .volumeFileName)
                try TerrainManifestAsset.validateVolumeReference(name)
                volumeFileName = name
            } else { volumeFileName = nil }

            if container.contains(.materials) {
                guard version >= 3 else { throw TerrainManifestError.malformed("material palette requires version 3") }
                materials = try container.decode(TerrainMaterialPalette.self, forKey: .materials)
            } else {
                materials = nil
            }
            meshPrototypes = []
            if container.contains(.meshPrototypes) {
                var palette = try container.nestedUnkeyedContainer(forKey: .meshPrototypes)
                if let count = palette.count, count > 256 { throw TerrainManifestError.malformed("mesh palette exceeds 256 entries") }
                var ids: Set<UInt16> = []
                while !palette.isAtEnd {
                    guard version >= 2, meshPrototypes.count < 256 else { throw TerrainManifestError.malformed("invalid mesh palette version or count") }
                    let reference = try palette.decode(TerrainMeshPrototypeReference.self)
                    try reference.validate()
                    guard ids.insert(reference.id).inserted else { throw TerrainManifestError.malformed("duplicate mesh prototype ID") }
                    meshPrototypes.append(reference)
                }
            }
            var list = try container.nestedUnkeyedContainer(forKey: .heightRegions)
            if let count = list.count, count > maximumRegions { throw TerrainManifestError.malformed("region table exceeds 16384 entries") }
            heightRegions = []
            heightRegions.reserveCapacity(list.count ?? 0)
            var references = References()
            while !list.isAtEnd {
                guard heightRegions.count < maximumRegions else { throw TerrainManifestError.malformed("region table exceeds 16384 entries") }
                let region = try list.decode(TerrainRegionReference.self)
                try references.validate(region)
                heightRegions.append(region)
            }
        }
    }

    public init(
        spacing: Float = 1,
        originX: Float = 0,
        originZ: Float = 0,
        heightRegions: [TerrainRegionReference] = [],
        meshPrototypes: [TerrainMeshPrototypeReference] = [],
        materials: TerrainMaterialPalette? = nil,
        volumeFileName: String? = nil,
        meshDocumentFileName: String? = nil
    ) {
        self.spacing = spacing; self.originX = originX; self.originZ = originZ; self.heightRegions = heightRegions; self.meshPrototypes = meshPrototypes
        self.materials = materials; self.volumeFileName = volumeFileName
        self.meshDocumentFileName = meshDocumentFileName
    }

    public init(data: Data) throws {
        guard data.count <= 4 * 1_024 * 1_024 else { throw TerrainManifestError.malformed("encoded byte budget exceeded") }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        self.init(
            spacing: payload.spacing,
            originX: payload.originX,
            originZ: payload.originZ,
            heightRegions: payload.heightRegions,
            meshPrototypes: payload.meshPrototypes,
            materials: payload.materials,
            volumeFileName: payload.volumeFileName,
            meshDocumentFileName: payload.meshDocumentFileName
        )
        try validate()
    }

    public func encodedData() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(
            Payload(
                version: meshDocumentFileName != nil ? 5 : (volumeFileName != nil ? 4 : (materials != nil ? 3 : (meshPrototypes.isEmpty ? 1 : 2))),
                spacing: spacing,
                originX: originX,
                originZ: originZ,
                heightRegions: heightRegions,
                meshPrototypes: meshPrototypes,
                materials: materials,
                volumeFileName: volumeFileName,
                meshDocumentFileName: meshDocumentFileName
            )
        )
    }

    /// Validates resource names, spatial bounds and the bounded region table before serialization.
    public func validate() throws {
        try Self.validateConfiguration(spacing: spacing, originX: originX, originZ: originZ)
        try materials?.validate()
        if let volumeFileName { try Self.validateVolumeReference(volumeFileName) }
        if let meshDocumentFileName {
            try Self.validateMeshReference(meshDocumentFileName)
            guard volumeFileName == nil, heightRegions.isEmpty else { throw TerrainManifestError.malformed("mesh surface and heightfield payloads cannot be mixed") }
        }
        guard heightRegions.count <= Self.maximumRegions else { throw TerrainManifestError.malformed("region table exceeds 16384 entries") }
        guard meshPrototypes.count <= 256 else { throw TerrainManifestError.malformed("mesh palette exceeds 256 entries") }
        var ids: Set<UInt16> = []
        for reference in meshPrototypes {
            try reference.validate()
            guard ids.insert(reference.id).inserted else { throw TerrainManifestError.malformed("duplicate mesh prototype ID") }
        }
        var references = References()
        for region in heightRegions { try references.validate(region) }
    }

    private static func validateMeshReference(_ name: String) throws {
        let bytes = name.utf8
        guard !bytes.isEmpty, bytes.count <= 128, name.hasSuffix(".atmesh"), let first = bytes.first, isAlphanumeric(first),
            bytes.allSatisfy({ isAlphanumeric($0) || $0 == 45 || $0 == 46 || $0 == 95 })
        else { throw TerrainManifestError.malformed("mesh document must be a local ASCII basename ending in .atmesh") }
    }

    private static func validateVolumeReference(_ name: String) throws {
        let bytes = name.utf8
        guard !bytes.isEmpty, bytes.count <= 128, name.hasSuffix(".atvolume"), let first = bytes.first, isAlphanumeric(first),
            bytes.allSatisfy({ isAlphanumeric($0) || $0 == 45 || $0 == 46 || $0 == 95 })
        else { throw TerrainManifestError.malformed("volume document file must be an ASCII basename ending in .atvolume, at most 128 bytes") }
    }

    private static func validateConfiguration(spacing: Float, originX: Float, originZ: Float) throws {
        let extent = Float(1_048_576) * spacing
        guard spacing.isFinite, spacing > 0, originX.isFinite, originZ.isFinite, extent.isFinite,
            (originX - extent).isFinite, (originX + extent).isFinite, (originZ - extent).isFinite, (originZ + extent).isFinite
        else {
            throw TerrainManifestError.malformed("invalid sample spacing or origin")
        }
    }

    private static func validateReference(_ region: TerrainRegionReference) throws {
        guard (-4_096...4_096).contains(region.x), (-4_096...4_096).contains(region.z) else {
            throw TerrainManifestError.malformed("region address is outside the supported grid")
        }
        let bytes = region.fileName.utf8
        guard !bytes.isEmpty, bytes.count <= 128, region.fileName.hasSuffix(".atregion"),
            let first = bytes.first, isAlphanumeric(first),
            bytes.allSatisfy({ isAlphanumeric($0) || $0 == 45 || $0 == 46 || $0 == 95 })
        else {
            throw TerrainManifestError.malformed("region file must be an ASCII basename ending in .atregion, at most 128 bytes")
        }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    public init(from assetDecoder: any AssetDecoder) async throws { try self.init(data: assetDecoder.assetData) }
    public func encodeContents(with assetEncoder: any AssetEncoder) async throws { try assetEncoder.encode(encodedData()) }
    public static func extensions() -> [String] { ["aterrain"] }
}
