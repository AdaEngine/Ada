import Foundation
import Math

public enum TerrainRegionError: LocalizedError {
    case malformed(String)
    case unsupportedVersion(String)

    public var errorDescription: String? {
        switch self {
        case let .malformed(reason): "Invalid terrain region: \(reason)"
        case let .unsupportedVersion(version): "Unsupported terrain region version: \(version)"
        }
    }
}

/// The dimensions of an allocated heightfield tile within a region's 4 by 4 tile grid.
public struct TerrainRegionTile: Codable, Equatable, Sendable {
    public let x: UInt8
    public let z: UInt8
    public let cellCountX: UInt8
    public let cellCountZ: UInt8

    public init(x: UInt8, z: UInt8, cellCountX: UInt8 = 64, cellCountZ: UInt8 = 64) {
        self.x = x; self.z = z; self.cellCountX = cellCountX; self.cellCountZ = cellCountZ
    }
}

/// One canonical 64 by 64 height page. Borders are owned by the page at their sample address.
public struct TerrainRegionHeightPage: Codable, Equatable, Sendable {
    public let x: UInt8
    public let z: UInt8
    public let samples: [Float]

    public init(x: UInt8, z: UInt8, samples: [Float]) { self.x = x; self.z = z; self.samples = samples }
}

/// An independently loadable region payload; no render resources or neighboring region loads are required.
public struct TerrainRegionAsset: Asset {
    public static let maximumEncodedBytes: Int? = 8 * 1_024 * 1_024
    public var assetMetaInfo: AssetMetaInfo?
    public let x: Int32
    public let z: Int32
    public let tiles: [TerrainRegionTile]
    public let pages: [TerrainRegionHeightPage]
    public let instances: [TerrainRegionInstance]
    public let surface: [TerrainRegionSurfaceSample]
    public let ruleMasks: [TerrainRegionRuleMaskSample]

    /// Only use after validation has bounded both record counts.
    var encodedByteCount: Int {
        Self.encodedSize(tileCount: tiles.count, pageCount: pages.count, instanceCount: instances.count, surfaceCount: surface.count, ruleMaskCount: ruleMasks.count)
    }

    public init(
        x: Int32,
        z: Int32,
        tiles: [TerrainRegionTile],
        pages: [TerrainRegionHeightPage],
        instances: [TerrainRegionInstance] = [],
        surface: [TerrainRegionSurfaceSample] = [],
        ruleMasks: [TerrainRegionRuleMaskSample] = []
    ) {
        self.x = x; self.z = z; self.tiles = tiles; self.pages = pages; self.instances = instances; self.surface = surface; self.ruleMasks = ruleMasks
    }

    public init(data: Data) throws {
        guard data.count <= (Self.maximumEncodedBytes ?? 0) else { throw TerrainRegionError.malformed("encoded byte budget exceeded") }
        guard data.count >= 24 else { throw TerrainRegionError.malformed("truncated header") }
        let signature = Array(data.prefix(8))
        guard signature.prefix(6).elementsEqual("ADATRN".utf8) else { throw TerrainRegionError.malformed("incorrect signature") }
        if signature[6] == 48 && signature[7] == 51 {
            self = try Self.decodeSurfaceData(data)
            return
        }
        if signature[6] == 48 && signature[7] == 50 {
            self = try Self.decodeInstanceData(data)
            return
        }
        guard signature[6] == 48, signature[7] == 49 else {
            throw TerrainRegionError.unsupportedVersion(String(bytes: signature[6..<8], encoding: .ascii) ?? "unknown")
        }
        guard data.count <= 512 * 1_024 else { throw TerrainRegionError.malformed("legacy encoded byte budget exceeded") }
        var reader = RegionReader(bytes: Array(data))
        reader.offset = 8
        let x = Int32(bitPattern: try reader.uint32()), z = Int32(bitPattern: try reader.uint32())
        let tileCount = try reader.uint32(), pageCount = try reader.uint32()
        // Bound integer counts and exact byte length before reserving or decoding any arrays.
        guard tileCount <= 16, pageCount <= 16 else { throw TerrainRegionError.malformed("record count exceeds 16") }
        let expectedSize = 24 + Int(tileCount) * 4 + Int(pageCount) * 16_388
        guard data.count == expectedSize else { throw TerrainRegionError.malformed("record length mismatch") }
        try Self.validateAddress(x: x, z: z, tileCount: Int(tileCount))
        var tiles: [TerrainRegionTile] = []
        var pages: [TerrainRegionHeightPage] = []
        tiles.reserveCapacity(Int(tileCount)); pages.reserveCapacity(Int(pageCount))
        for _ in 0..<tileCount {
            tiles.append(try .init(x: reader.byte(), z: reader.byte(), cellCountX: reader.byte(), cellCountZ: reader.byte()))
        }
        for _ in 0..<pageCount {
            let localX = try reader.byte(), localZ = try reader.byte()
            guard try reader.byte() == 0, try reader.byte() == 0 else { throw TerrainRegionError.malformed("nonzero reserved page bytes") }
            var samples: [Float] = []
            samples.reserveCapacity(4_096)
            for _ in 0..<4_096 {
                let sample = Float(bitPattern: try reader.uint32())
                guard sample.isFinite else { throw TerrainRegionError.malformed("nonfinite height sample") }
                samples.append(sample)
            }
            pages.append(.init(x: localX, z: localZ, samples: samples))
        }
        self.init(x: x, z: z, tiles: tiles, pages: pages)
        try validate()
    }

    public func encodedData() throws -> Data {
        try validate()
        if !surface.isEmpty || !ruleMasks.isEmpty {
            return try encodedSurfaceData()
        }
        if !instances.isEmpty {
            return try encodedInstanceData()
        }
        var data = Data("ADATRN01".utf8)
        data.reserveCapacity(encodedByteCount)
        Self.append(UInt32(bitPattern: x), to: &data); Self.append(UInt32(bitPattern: z), to: &data)
        Self.append(UInt32(tiles.count), to: &data); Self.append(UInt32(pages.count), to: &data)
        for tile in tiles { data.append(contentsOf: [tile.x, tile.z, tile.cellCountX, tile.cellCountZ]) }
        for page in pages {
            data.append(contentsOf: [page.x, page.z, 0, 0])
            for sample in page.samples { Self.append(sample.bitPattern, to: &data) }
        }
        return data
    }

    /// Checks both physical tiles and canonical data-only pages at the positive grid boundary.
    public func validate() throws {
        guard tiles.count <= 16, pages.count <= 16, instances.count <= Self.maximumInstances else {
            throw TerrainRegionError.malformed("region record count exceeds its budget")
        }
        try Self.validateRecordBudget(
            tileCount: tiles.count,
            pageCount: pages.count,
            instanceCount: instances.count,
            surfaceCount: surface.count,
            ruleMaskCount: ruleMasks.count
        )
        try Self.validateAddress(x: x, z: z, tileCount: tiles.count)
        try validateSurface()
        var tileIDs: Set<Int> = [], pageIDs: Set<Int> = []
        for tile in tiles {
            guard tile.x < 4, tile.z < 4, (1...64).contains(tile.cellCountX), (1...64).contains(tile.cellCountZ),
                tileIDs.insert(Int(tile.z) * 4 + Int(tile.x)).inserted
            else {
                throw TerrainRegionError.malformed("invalid or duplicate tile")
            }
        }
        for page in pages {
            guard page.x < 4, page.z < 4, page.samples.count == 4_096,
                pageIDs.insert(Int(page.z) * 4 + Int(page.x)).inserted,
                x != 4_096 || page.x == 0, z != 4_096 || page.z == 0
            else {
                throw TerrainRegionError.malformed("invalid or duplicate height page")
            }
            for (index, sample) in page.samples.enumerated() {
                guard sample.isFinite,
                    x != 4_096 || index % 64 == 0 || sample == 0,
                    z != 4_096 || index / 64 == 0 || sample == 0
                else {
                    throw TerrainRegionError.malformed("invalid height sample")
                }
            }
        }
        var instanceIDs: Set<UInt64> = []
        instanceIDs.reserveCapacity(instances.count)
        for instance in instances {
            try instance.validate()
            guard instanceIDs.insert(instance.id).inserted,
                x != 4_096 || instance.localPosition.x == 0, z != 4_096 || instance.localPosition.z == 0
            else {
                throw TerrainRegionError.malformed("duplicate instance identity or position outside the grid")
            }
        }
    }

    private static func validateAddress(x: Int32, z: Int32, tileCount: Int) throws {
        guard (-4_096...4_096).contains(x), (-4_096...4_096).contains(z) else {
            throw TerrainRegionError.malformed("region address is outside the supported grid")
        }
        guard (x < 4_096 && z < 4_096) || tileCount == 0 else {
            throw TerrainRegionError.malformed("the positive boundary can only contain canonical sample pages")
        }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }

    public init(from assetDecoder: any AssetDecoder) async throws { try self.init(data: assetDecoder.assetData) }
    public func encodeContents(with assetEncoder: any AssetEncoder) async throws { try assetEncoder.encode(encodedData()) }
    public static func extensions() -> [String] { ["atregion"] }
}

private struct RegionReader {
    let bytes: [UInt8]
    var offset = 0

    mutating func byte() throws -> UInt8 {
        guard offset < bytes.count else { throw TerrainRegionError.malformed("truncated record") }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func uint32() throws -> UInt32 {
        var value: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) { value |= UInt32(try byte()) << shift }
        return value
    }
}
