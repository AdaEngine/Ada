import Foundation
import Math

extension TerrainRegionAsset {
    static let maximumInstances = 65_536
    static let instanceRecordBytes = 64

    var instanceEncodedByteCount: Int {
        Self.encodedSize(tileCount: tiles.count, pageCount: pages.count, instanceCount: instances.count, surfaceCount: 0, ruleMaskCount: 0)
    }

    func encodedInstanceData() throws -> Data {
        var height = Data()
        if !tiles.isEmpty || !pages.isEmpty {
            let base = TerrainRegionAsset(x: x, z: z, tiles: tiles, pages: pages)
            height = Data(try base.encodedData().dropFirst(16))
        }
        var bytes = Data("ADATRN02".utf8)
        bytes.reserveCapacity(instanceEncodedByteCount)
        InstanceWords.append(UInt32(bitPattern: x), to: &bytes)
        InstanceWords.append(UInt32(bitPattern: z), to: &bytes)
        InstanceWords.append(UInt32(height.isEmpty ? 1 : 2), to: &bytes)
        InstanceWords.append(UInt32(0), to: &bytes)
        if !height.isEmpty {
            Self.appendSection(tag: 1, count: UInt32(tiles.count + pages.count), length: height.count, to: &bytes)
        }
        Self.appendSection(tag: 2, count: UInt32(instances.count), length: instances.count * Self.instanceRecordBytes, to: &bytes)
        bytes.append(height)
        for instance in instances {
            InstanceWords.append(instance.id, to: &bytes)
            InstanceWords.append(instance.prototypeID, to: &bytes)
            InstanceWords.append(instance.flags.rawValue, to: &bytes)
            InstanceWords.append(instance.localPosition.x.bitPattern, to: &bytes)
            InstanceWords.append(instance.localPosition.y.bitPattern, to: &bytes)
            InstanceWords.append(instance.localPosition.z.bitPattern, to: &bytes)
            InstanceWords.append(instance.rotationBits, to: &bytes)
            InstanceWords.append(instance.scale.x.bitPattern, to: &bytes)
            InstanceWords.append(instance.scale.y.bitPattern, to: &bytes)
            InstanceWords.append(instance.scale.z.bitPattern, to: &bytes)
            InstanceWords.append(instance.tintBits, to: &bytes)
            InstanceWords.append(instance.seed, to: &bytes)
            InstanceWords.append(instance.normalBits, to: &bytes)
            InstanceWords.append(instance.anchorOffset.bitPattern, to: &bytes)
            InstanceWords.append(UInt32(0), to: &bytes)
        }
        return bytes
    }

    private static func appendSection(tag: UInt16, count: UInt32, length: Int, to data: inout Data) {
        InstanceWords.append(tag, to: &data)
        InstanceWords.append(UInt16(1), to: &data)
        InstanceWords.append(count, to: &data)
        InstanceWords.append(UInt64(length), to: &data)
    }

    static func decodeInstanceData(_ data: Data) throws -> TerrainRegionAsset {
        var reader = InstanceReader(bytes: Array(data), offset: 8)
        let x = Int32(bitPattern: try reader.uint32()), z = Int32(bitPattern: try reader.uint32())
        try TerrainRegionAsset(x: x, z: z, tiles: [], pages: []).validate()
        let sectionCount = try reader.uint32(), flags = try reader.uint32()
        guard (1...2).contains(sectionCount), flags == 0, reader.bytes.count >= 24 + Int(sectionCount) * 16 else {
            throw TerrainRegionError.malformed("invalid section table")
        }
        struct Section {
            let tag: UInt16
            let count: Int
            let offset: Int
            let length: Int
        }
        var sections: [Section] = []
        var payloadOffset = 24 + Int(sectionCount) * 16
        var previousTag: UInt16 = 0
        for _ in 0..<sectionCount {
            let tag = try reader.uint16(), version = try reader.uint16()
            let count = try reader.uint32(), length = try reader.uint64()
            guard (1...2).contains(tag), version == 1 else {
                throw TerrainRegionError.unsupportedVersion("section \(tag), version \(version)")
            }
            guard tag > previousTag, payloadOffset <= reader.bytes.count, length <= UInt64(reader.bytes.count - payloadOffset) else {
                throw TerrainRegionError.malformed("duplicate, unordered or truncated section")
            }
            if tag == 1 {
                guard count > 0, count <= 32, length <= 512 * 1_024 - 16 else { throw TerrainRegionError.malformed("height section budget exceeded") }
            } else {
                guard count > 0, count <= UInt32(maximumInstances), length == UInt64(count) * UInt64(instanceRecordBytes) else {
                    throw TerrainRegionError.malformed("instance section count or length mismatch")
                }
            }
            sections.append(Section(tag: tag, count: Int(count), offset: payloadOffset, length: Int(length)))
            payloadOffset += Int(length)
            previousTag = tag
        }
        guard payloadOffset == reader.bytes.count, sections.last?.tag == 2 else {
            throw TerrainRegionError.malformed("unexpected trailing data or missing placement section")
        }
        var heights = TerrainRegionAsset(x: x, z: z, tiles: [], pages: [])
        var records: [TerrainRegionInstance] = []
        for section in sections {
            if section.tag == 1 {
                var legacy = Data("ADATRN01".utf8)
                InstanceWords.append(UInt32(bitPattern: x), to: &legacy)
                InstanceWords.append(UInt32(bitPattern: z), to: &legacy)
                legacy.append(contentsOf: reader.bytes[section.offset..<(section.offset + section.length)])
                heights = try TerrainRegionAsset(data: legacy)
                guard heights.tiles.count + heights.pages.count == section.count else {
                    throw TerrainRegionError.malformed("height section record count mismatch")
                }
            } else {
                reader.offset = section.offset
                records.reserveCapacity(section.count)
                for _ in 0..<section.count { records.append(try reader.instance()) }
                guard reader.offset == section.offset + section.length else { throw TerrainRegionError.malformed("instance section mismatch") }
            }
        }
        let result = TerrainRegionAsset(x: x, z: z, tiles: heights.tiles, pages: heights.pages, instances: records)
        try result.validate()
        return result
    }
}

private enum InstanceWords {
    static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        for shift in stride(from: 0, to: T.bitWidth, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
}

private struct InstanceReader {
    let bytes: [UInt8]
    var offset: Int

    mutating func uint16() throws -> UInt16 { try UInt16(word(bytes: 2)) }
    mutating func uint32() throws -> UInt32 { try UInt32(word(bytes: 4)) }
    mutating func uint64() throws -> UInt64 { try word(bytes: 8) }
    mutating func float() throws -> Float { Float(bitPattern: try uint32()) }

    private mutating func word(bytes count: Int) throws -> UInt64 {
        guard offset <= bytes.count, count <= bytes.count - offset else { throw TerrainRegionError.malformed("truncated placement record") }
        var result: UInt64 = 0
        for shift in stride(from: 0, to: count * 8, by: 8) {
            result |= UInt64(bytes[offset]) << shift
            offset += 1
        }
        return result
    }

    mutating func instance() throws -> TerrainRegionInstance {
        let id = try uint64(), prototype = try uint16(), flags = try uint16()
        let position = try Vector3(float(), float(), float())
        let rotation = try uint64()
        let scale = try Vector3(float(), float(), float())
        let tint = try uint32(), seed = try uint32(), normal = try uint32(), anchorOffset = try float()
        guard try uint32() == 0 else { throw TerrainRegionError.malformed("nonzero reserved placement word") }
        return try TerrainRegionInstance(
            id: id,
            prototypeID: prototype,
            localPosition: position,
            rotationBits: rotation,
            scale: scale,
            tintBits: tint,
            seed: seed,
            flags: .init(rawValue: flags),
            normalBits: normal,
            anchorOffset: anchorOffset
        )
    }
}
