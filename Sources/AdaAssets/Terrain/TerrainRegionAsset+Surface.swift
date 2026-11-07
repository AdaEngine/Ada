import Foundation
import Math

extension TerrainRegionAsset {
    static let maximumSurfaceSamples = 65_536
    static let maximumRuleMaskSamples = 262_144

    var surfaceEncodedByteCount: Int {
        Self.encodedSize(tileCount: tiles.count, pageCount: pages.count, instanceCount: instances.count, surfaceCount: surface.count, ruleMaskCount: ruleMasks.count)
    }

    func validateSurface() throws {
        guard surface.count <= Self.maximumSurfaceSamples, ruleMasks.count <= Self.maximumRuleMaskSamples else {
            throw TerrainRegionError.malformed("surface record count exceeds its budget")
        }
        var samples: Set<UInt16> = []
        for sample in surface {
            try sample.validate()
            let key = UInt16(sample.z) * 256 + UInt16(sample.x)
            guard samples.insert(key).inserted, x != 4_096 || sample.x == 0, z != 4_096 || sample.z == 0 else {
                throw TerrainRegionError.malformed("duplicate surface sample or sample outside the grid")
            }
        }
        var masks: Set<UInt32> = []
        for sample in ruleMasks {
            try sample.validate()
            let key = UInt32(sample.maskID) << 16 | UInt32(sample.z) << 8 | UInt32(sample.x)
            guard masks.insert(key).inserted, x != 4_096 || sample.x == 0, z != 4_096 || sample.z == 0 else {
                throw TerrainRegionError.malformed("duplicate rule mask or mask outside the grid")
            }
        }
        guard surfaceEncodedByteCount <= (Self.maximumEncodedBytes ?? 0) else { throw TerrainRegionError.malformed("encoded byte budget exceeded") }
    }

    func encodedSurfaceData() throws -> Data {
        var sections: [(tag: UInt16, count: Int, bytes: Data)] = []
        if !tiles.isEmpty || !pages.isEmpty {
            let base = TerrainRegionAsset(x: x, z: z, tiles: tiles, pages: pages)
            sections.append((1, tiles.count + pages.count, Data(try base.encodedData().dropFirst(16))))
        }
        if !instances.isEmpty {
            let base = TerrainRegionAsset(x: x, z: z, tiles: [], pages: [], instances: instances)
            sections.append((2, instances.count, Data(try base.encodedData().suffix(instances.count * 64))))
        }
        if !surface.isEmpty {
            var payload = Data()
            payload.reserveCapacity(surface.count * 64)
            for sample in surface {
                payload.append(contentsOf: [sample.x, sample.z, 0, 0])
                for channel in 0..<4 { SurfaceWords.append(sample.layerIDs[channel], to: &payload) }
                for channel in 0..<4 { SurfaceWords.append(sample.weights[channel].bitPattern, to: &payload) }
                SurfaceWords.append(sample.overrideStrength.bitPattern, to: &payload)
                for channel in 0..<4 { SurfaceWords.append(sample.tint[channel].bitPattern, to: &payload) }
                for value in [sample.tintStrength, sample.roughness, sample.roughnessStrength] { SurfaceWords.append(value.bitPattern, to: &payload) }
                SurfaceWords.append(UInt32(0), to: &payload)
            }
            sections.append((3, surface.count, payload))
        }
        if !ruleMasks.isEmpty {
            var payload = Data()
            payload.reserveCapacity(ruleMasks.count * 8)
            for sample in ruleMasks {
                payload.append(contentsOf: [sample.x, sample.z])
                SurfaceWords.append(sample.maskID, to: &payload)
                SurfaceWords.append(sample.value.bitPattern, to: &payload)
            }
            sections.append((4, ruleMasks.count, payload))
        }
        var data = Data("ADATRN03".utf8)
        data.reserveCapacity(surfaceEncodedByteCount)
        SurfaceWords.append(UInt32(bitPattern: x), to: &data)
        SurfaceWords.append(UInt32(bitPattern: z), to: &data)
        SurfaceWords.append(UInt32(sections.count), to: &data)
        SurfaceWords.append(UInt32(0), to: &data)
        for section in sections { Self.appendSurfaceSection(tag: section.tag, count: section.count, length: section.bytes.count, to: &data) }
        for section in sections { data.append(section.bytes) }
        return data
    }

    static func decodeSurfaceData(_ data: Data) throws -> TerrainRegionAsset {
        var reader = SurfaceWords.Reader(bytes: Array(data), offset: 8)
        let x = Int32(bitPattern: try reader.uint32()), z = Int32(bitPattern: try reader.uint32())
        try TerrainRegionAsset(x: x, z: z, tiles: [], pages: []).validate()
        let count = try reader.uint32(), flags = try reader.uint32()
        guard (1...4).contains(count), flags == 0, data.count >= 24 + Int(count) * 16 else {
            throw TerrainRegionError.malformed("invalid surface section table")
        }
        var sections: [(tag: UInt16, count: Int, offset: Int, length: Int)] = []
        var offset = 24 + Int(count) * 16
        var previousTag: UInt16 = 0
        for _ in 0..<count {
            let tag = try reader.uint16(), version = try reader.uint16(), records = try reader.uint32(), length = try reader.uint64()
            guard (1...4).contains(tag), version == 1 else { throw TerrainRegionError.unsupportedVersion("surface section \(tag), version \(version)") }
            guard tag > previousTag, records > 0, offset <= data.count, length <= UInt64(data.count - offset) else {
                throw TerrainRegionError.malformed("duplicate, unordered or truncated surface section")
            }
            let limit = tag == 1 ? 32 : (tag == 2 ? maximumInstances : (tag == 3 ? maximumSurfaceSamples : maximumRuleMaskSamples))
            guard records <= UInt32(limit) else { throw TerrainRegionError.malformed("surface section record budget exceeded") }
            if tag == 1 {
                guard length <= 512 * 1_024 - 16 else { throw TerrainRegionError.malformed("height section budget exceeded") }
            } else {
                let stride = tag == 4 ? 8 : 64
                guard length == UInt64(records) * UInt64(stride) else { throw TerrainRegionError.malformed("surface section length mismatch") }
            }
            sections.append((tag, Int(records), offset, Int(length)))
            offset += Int(length)
            previousTag = tag
        }
        guard offset == data.count, sections.contains(where: { $0.tag >= 3 }) else {
            throw TerrainRegionError.malformed("trailing bytes or missing surface sections")
        }
        var height = TerrainRegionAsset(x: x, z: z, tiles: [], pages: [])
        var instances: [TerrainRegionInstance] = [], surface: [TerrainRegionSurfaceSample] = [], masks: [TerrainRegionRuleMaskSample] = []
        for section in sections {
            reader.offset = section.offset
            switch section.tag {
            case 1:
                var legacy = Data("ADATRN01".utf8)
                SurfaceWords.append(UInt32(bitPattern: x), to: &legacy)
                SurfaceWords.append(UInt32(bitPattern: z), to: &legacy)
                legacy.append(contentsOf: reader.bytes[section.offset..<(section.offset + section.length)])
                height = try TerrainRegionAsset(data: legacy)
                guard height.tiles.count + height.pages.count == section.count else { throw TerrainRegionError.malformed("height record count mismatch") }
                reader.offset += section.length
            case 2:
                var legacy = Data("ADATRN02".utf8)
                SurfaceWords.append(UInt32(bitPattern: x), to: &legacy)
                SurfaceWords.append(UInt32(bitPattern: z), to: &legacy)
                SurfaceWords.append(UInt32(1), to: &legacy)
                SurfaceWords.append(UInt32(0), to: &legacy)
                appendSurfaceSection(tag: 2, count: section.count, length: section.length, to: &legacy)
                legacy.append(contentsOf: reader.bytes[section.offset..<(section.offset + section.length)])
                instances = try TerrainRegionAsset(data: legacy).instances
                reader.offset += section.length
            case 3:
                surface.reserveCapacity(section.count)
                for _ in 0..<section.count { surface.append(try reader.surface()) }
            default:
                masks.reserveCapacity(section.count)
                for _ in 0..<section.count {
                    masks.append(try .init(x: reader.byte(), z: reader.byte(), maskID: reader.uint16(), value: reader.float()))
                }
            }
            guard reader.offset == section.offset + section.length else { throw TerrainRegionError.malformed("surface payload mismatch") }
        }
        let result = TerrainRegionAsset(x: x, z: z, tiles: height.tiles, pages: height.pages, instances: instances, surface: surface, ruleMasks: masks)
        try result.validate()
        return result
    }

    private static func appendSurfaceSection(tag: UInt16, count: Int, length: Int, to data: inout Data) {
        SurfaceWords.append(tag, to: &data)
        SurfaceWords.append(UInt16(1), to: &data)
        SurfaceWords.append(UInt32(count), to: &data)
        SurfaceWords.append(UInt64(length), to: &data)
    }
}

private enum SurfaceWords {
    static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        for shift in stride(from: 0, to: T.bitWidth, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }

    struct Reader {
        let bytes: [UInt8]
        var offset: Int

        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw TerrainRegionError.malformed("truncated surface sample") }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func uint16() throws -> UInt16 { try UInt16(word(count: 2)) }
        mutating func uint32() throws -> UInt32 { try UInt32(word(count: 4)) }
        mutating func uint64() throws -> UInt64 { try word(count: 8) }
        mutating func float() throws -> Float { Float(bitPattern: try uint32()) }

        private mutating func word(count: Int) throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: count * 8, by: 8) { value |= UInt64(try byte()) << shift }
            return value
        }

        mutating func surface() throws -> TerrainRegionSurfaceSample {
            let x = try byte(), z = try byte()
            guard try uint16() == 0 else { throw TerrainRegionError.malformed("nonzero reserved surface word") }
            let ids = try SIMD4<UInt16>(uint16(), uint16(), uint16(), uint16())
            let weights = try Vector4(float(), float(), float(), float())
            let opacity = try float(), tint = try Vector4(float(), float(), float(), float())
            let tintStrength = try float(), roughness = try float(), roughnessStrength = try float()
            guard try uint32() == 0 else { throw TerrainRegionError.malformed("nonzero reserved surface word") }
            return .init(
                x: x,
                z: z,
                layerIDs: ids,
                weights: weights,
                overrideStrength: opacity,
                tint: tint,
                tintStrength: tintStrength,
                roughness: roughness,
                roughnessStrength: roughnessStrength
            )
        }
    }
}
