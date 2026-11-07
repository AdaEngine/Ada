import Foundation

public enum TerrainVolumeAssetError: LocalizedError, Equatable, Sendable {
    case malformed(String)
    case unsupportedVersion(String)

    public var errorDescription: String? {
        switch self {
        case let .malformed(reason): "Invalid terrain volume: \(reason)"
        case let .unsupportedVersion(version): "Unsupported terrain volume version: \(version)"
        }
    }
}

/// Canonical 33-cubed samples for an independently loadable 32-cell volume brick.
public struct TerrainVolumeBrickAsset: Asset {
    public static let sampleCount = 33 * 33 * 33
    public static let unassignedMaterial = UInt32.max
    public static let maximumEncodedBytes: Int? = 24 + sampleCount * 8
    public var assetMetaInfo: AssetMetaInfo?
    public let x: Int32
    public let y: Int32
    public let z: Int32
    public let values: [Float]
    /// Stable UInt16 layer ID, or unassignedMaterial to use terrain rules/interior fallback.
    public let materialTags: [UInt32]

    public init(x: Int32, y: Int32, z: Int32, values: [Float], materialTags: [UInt32]) {
        self.x = x; self.y = y; self.z = z; self.values = values; self.materialTags = materialTags
    }

    public init(data: Data) throws {
        try Task.checkCancellation()
        guard data.count == Self.maximumEncodedBytes else { throw TerrainVolumeAssetError.malformed("incorrect volume brick byte count") }
        // A Data slice need not start at zero. The bounded byte copy supplies canonical indices.
        let bytes = Array(data)
        guard bytes.prefix(6).elementsEqual("ADAVOL".utf8) else { throw TerrainVolumeAssetError.malformed("incorrect volume brick signature") }
        guard bytes[6] == 48, bytes[7] == 49 else {
            throw TerrainVolumeAssetError.unsupportedVersion(String(bytes: bytes[6..<8], encoding: .ascii) ?? "unknown")
        }
        let x = Int32(bitPattern: Self.read(bytes, at: 8)), y = Int32(bitPattern: Self.read(bytes, at: 12)), z = Int32(bitPattern: Self.read(bytes, at: 16))
        try Self.validateAddress(x, y, z)
        guard Self.read(bytes, at: 20) == UInt32(Self.sampleCount) else { throw TerrainVolumeAssetError.malformed("incorrect volume sample count") }
        // Validate the complete bounded payload before allocating either decoded sample array.
        for index in 0..<Self.sampleCount {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let offset = 24 + index * 8
            let value = Float(bitPattern: Self.read(bytes, at: offset)), tag = Self.read(bytes, at: offset + 4)
            guard value.isFinite, tag <= UInt32(UInt16.max) || tag == Self.unassignedMaterial else {
                throw TerrainVolumeAssetError.malformed("nonfinite volume density or invalid material tag")
            }
        }
        var values: [Float] = [], tags: [UInt32] = []
        values.reserveCapacity(Self.sampleCount); tags.reserveCapacity(Self.sampleCount)
        for index in 0..<Self.sampleCount {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let offset = 24 + index * 8
            values.append(Float(bitPattern: Self.read(bytes, at: offset)))
            tags.append(Self.read(bytes, at: offset + 4))
        }
        self.init(x: x, y: y, z: z, values: values, materialTags: tags)
    }

    public func encodedData() throws -> Data {
        try validate()
        var data = Data("ADAVOL01".utf8)
        data.reserveCapacity(Self.maximumEncodedBytes ?? 0)
        Self.append(UInt32(bitPattern: x), to: &data); Self.append(UInt32(bitPattern: y), to: &data); Self.append(UInt32(bitPattern: z), to: &data)
        Self.append(UInt32(Self.sampleCount), to: &data)
        for index in values.indices {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            Self.append(values[index].bitPattern, to: &data); Self.append(materialTags[index], to: &data)
        }
        return data
    }

    public func validate() throws {
        try Task.checkCancellation()
        try Self.validateAddress(x, y, z)
        guard values.count == Self.sampleCount, materialTags.count == Self.sampleCount else {
            throw TerrainVolumeAssetError.malformed("volume bricks require exactly 33 cubed density samples and tags")
        }
        for index in values.indices {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let tag = materialTags[index]
            guard values[index].isFinite, tag <= UInt32(UInt16.max) || tag == Self.unassignedMaterial else {
                throw TerrainVolumeAssetError.malformed("nonfinite volume density or invalid material tag")
            }
        }
    }

    private static func validateAddress(_ x: Int32, _ y: Int32, _ z: Int32) throws {
        guard (-32_768..<32_768).contains(x), (-32_768..<32_768).contains(y), (-32_768..<32_768).contains(z) else {
            throw TerrainVolumeAssetError.malformed("volume brick address is outside the supported lattice")
        }
    }

    private static func read(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        // Callers establish exact payload length and bounded record indices first.
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    public init(from assetDecoder: any AssetDecoder) async throws { try self.init(data: assetDecoder.assetData) }
    public func encodeContents(with assetEncoder: any AssetEncoder) async throws { try assetEncoder.encode(encodedData()) }
    public static func extensions() -> [String] { ["atvolbrick"] }
}
