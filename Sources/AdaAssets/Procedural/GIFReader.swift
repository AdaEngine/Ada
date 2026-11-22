//
//  GIFReader.swift
//  AdaEngine
//

import Foundation

/// One decoded GIF frame: full-canvas palette indices and its delay.
public struct GIFDecodedFrame: Sendable, Equatable {
    public let indices: [UInt8]
    public let delayMilliseconds: Int
}

/// A decoded indexed-color GIF image.
public struct GIFImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let palette: [PixelColor]
    public let frames: [GIFDecodedFrame]
    public let loops: Bool
}

public enum GIFReadingError: Error, Equatable, LocalizedError {
    case truncated
    case notGIF
    case unsupported(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .truncated: "The GIF data ends unexpectedly."
        case .notGIF: "Not a GIF file."
        case let .unsupported(feature): "Unsupported GIF feature: \(feature)."
        case let .malformed(message): "Malformed GIF: \(message)."
        }
    }
}

/// Decodes non-interlaced GIF87a/GIF89a files with a global color table — the shape
/// ``GIFWriter`` produces, and the common case for pixel-art exports.
public struct GIFReader {
    public init() {}

    public func decode(_ data: Data) throws -> GIFImage {
        var cursor = Cursor(data)
        let signature = try cursor.bytes(6)
        guard signature == [0x47, 0x49, 0x46, 0x38, 0x39, 0x61] || signature == [0x47, 0x49, 0x46, 0x38, 0x37, 0x61] else {
            throw GIFReadingError.notGIF
        }
        let width = try cursor.le16()
        let height = try cursor.le16()
        guard width > 0, height > 0 else { throw GIFReadingError.malformed("zero-sized canvas") }
        guard width <= GIFWriter.maximumDecodedPixels / height else { throw GIFReadingError.unsupported("canvas pixel budget") }
        let pixelsPerFrame = width * height
        let packed = try cursor.byte()
        _ = try cursor.byte() // background index
        _ = try cursor.byte() // aspect
        guard packed & 0x80 != 0 else { throw GIFReadingError.unsupported("missing global color table") }
        let tableCount = 1 << (Int(packed & 0x07) + 1)
        var palette: [PixelColor] = []
        palette.reserveCapacity(tableCount)
        for _ in 0..<tableCount {
            palette.append(PixelColor(red: try cursor.byte(), green: try cursor.byte(), blue: try cursor.byte()))
        }

        var frames: [GIFDecodedFrame] = []
        var loops = false
        var delay = 0
        var transparentIndex: Int?
        while cursor.hasMore {
            let marker = try cursor.byte()
            switch marker {
            case 0x3B:
                cursor.stop()
            case 0x21:
                let label = try cursor.byte()
                if label == 0xF9 {
                    guard try cursor.byte() == 4 else { throw GIFReadingError.malformed("graphic control block") }
                    let control = try cursor.byte()
                    delay = Int(try cursor.le16()) * 10
                    let transparent = Int(try cursor.byte())
                    transparentIndex = control & 0x01 != 0 ? transparent : nil
                    _ = try cursor.byte() // block terminator
                } else if label == 0xFF {
                    let blockSize = Int(try cursor.byte())
                    let name = try cursor.bytes(blockSize)
                    if String(bytes: name, encoding: .utf8)?.hasPrefix("NETSCAPE") == true {
                        _ = try cursor.byte() // sub-block size 3
                        _ = try cursor.byte() // sub-block id 1
                        loops = try cursor.le16() == 0
                        _ = try cursor.byte() // terminator
                    } else {
                        try cursor.skipSubBlocks()
                    }
                } else {
                    try cursor.skipSubBlocks()
                }
            case 0x2C:
                let left = try cursor.le16()
                let top = try cursor.le16()
                let frameWidth = try cursor.le16()
                let frameHeight = try cursor.le16()
                let imagePacked = try cursor.byte()
                guard imagePacked & 0x80 == 0 else { throw GIFReadingError.unsupported("local color tables") }
                guard imagePacked & 0x40 == 0 else { throw GIFReadingError.unsupported("interlaced frames") }
                guard left == 0, top == 0, frameWidth == width, frameHeight == height else {
                    throw GIFReadingError.unsupported("partial-frame updates")
                }
                guard frames.count < GIFWriter.maximumFrames, frames.count < GIFWriter.maximumDecodedPixels / pixelsPerFrame else {
                    throw GIFReadingError.unsupported("animation frame budget")
                }
                let minimumCodeSize = Int(try cursor.byte())
                guard (2...8).contains(minimumCodeSize) else { throw GIFReadingError.malformed("LZW minimum code size") }
                let compressed = try cursor.subBlockData()
                let pixels = try Self.lzwDecode(compressed, minimumCodeSize: minimumCodeSize, expected: pixelsPerFrame)
                guard pixels.allSatisfy({ Int($0) < tableCount }) else { throw GIFReadingError.malformed("palette index out of range") }
                frames.append(GIFDecodedFrame(indices: pixels, delayMilliseconds: delay))
                delay = 0
            default:
                throw GIFReadingError.malformed("unexpected block 0x\(String(marker, radix: 16))")
            }
        }
        guard !frames.isEmpty else { throw GIFReadingError.malformed("no frames") }
        if let transparentIndex, transparentIndex < palette.count {
            palette[transparentIndex].alpha = 0
        }
        return GIFImage(width: width, height: height, palette: palette, frames: frames, loops: loops)
    }

    // MARK: - LZW

    static func lzwDecode(_ data: [UInt8], minimumCodeSize: Int, expected: Int) throws -> [UInt8] {
        let clearCode = 1 << minimumCodeSize
        let endCode = clearCode + 1
        var table: [[Int]] = (0...endCode).map { [$0] }
        var codeSize = minimumCodeSize + 1
        var output: [Int] = []
        output.reserveCapacity(expected)
        var bitIndex = 0

        func readCode() -> Int? {
            guard bitIndex + codeSize <= data.count * 8 else {
                return nil
            }
            var code = 0
            for bit in 0..<codeSize {
                let position = bitIndex + bit
                code |= ((Int(data[position / 8]) >> (position % 8)) & 1) << bit
            }
            bitIndex += codeSize
            return code
        }

        var previous: [Int]?
        while let code = readCode() {
            if code == clearCode {
                table = (0...endCode).map { [$0] }
                codeSize = minimumCodeSize + 1
                previous = nil
                continue
            }
            if code == endCode { break }
            let entry: [Int]
            if code < table.count {
                entry = table[code]
            } else if code == table.count, let previous {
                entry = previous + [previous[0]]
            } else {
                throw GIFReadingError.malformed("LZW code out of range")
            }
            output.append(contentsOf: entry)
            if let previous, table.count < 4096 {
                table.append(previous + [entry[0]])
                if table.count == (1 << codeSize), codeSize < 12 {
                    codeSize += 1
                }
            }
            previous = entry
            guard output.count <= expected else { throw GIFReadingError.malformed("LZW stream overruns the frame") }
        }
        guard output.count == expected else {
            throw GIFReadingError.malformed("LZW decoded \(output.count) of \(expected) pixels")
        }
        return output.map { UInt8($0 & 0xFF) }
    }

    // MARK: - Cursor

    private struct Cursor {
        let data: Data
        var offset = 0
        var hasMore = true

        init(_ data: Data) { self.data = data }

        var remaining: Int { data.count - offset }

        mutating func stop() { hasMore = false }

        mutating func byte() throws -> UInt8 {
            guard remaining >= 1 else { throw GIFReadingError.truncated }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func le16() throws -> Int {
            guard remaining >= 2 else { throw GIFReadingError.truncated }
            defer { offset += 2 }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }

        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard remaining >= count else { throw GIFReadingError.truncated }
            defer { offset += count }
            return Array(data[offset..<(offset + count)])
        }

        mutating func skipSubBlocks() throws {
            while true {
                let size = Int(try byte())
                if size == 0 {
                    return
                }
                _ = try bytes(size)
            }
        }

        mutating func subBlockData() throws -> [UInt8] {
            var result: [UInt8] = []
            while true {
                let size = Int(try byte())
                if size == 0 {
                    return result
                }
                result.append(contentsOf: try bytes(size))
            }
        }
    }
}
