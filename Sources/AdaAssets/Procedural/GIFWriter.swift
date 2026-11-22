//
//  GIFWriter.swift
//  AdaEngine
//

import Foundation

/// One frame of an indexed-color GIF animation.
public struct GIFAnimationFrame: Sendable, Equatable {
    /// Palette indices, `width * height` values in row-major order. Index 0 is transparent.
    public let indices: [UInt8]
    public let delayMilliseconds: Int

    public init(indices: [UInt8], delayMilliseconds: Int) {
        self.indices = indices
        self.delayMilliseconds = delayMilliseconds
    }
}

public enum GIFWritingError: Error, Equatable, LocalizedError {
    case invalidSize(width: Int, height: Int)
    case invalidScale(Int)
    case emptyAnimation
    case tooManyFrames(Int)
    case pixelBudgetExceeded
    case mismatchedFrame(Int, expected: Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidSize(width, height): "GIF size must be in 1...1024 per side, got \(width)x\(height)."
        case let .invalidScale(scale): "GIF scale must be an integer in 1...16, got \(scale)."
        case .emptyAnimation: "A GIF needs at least one frame."
        case let .tooManyFrames(count): "A GIF supports at most 256 frames, got \(count)."
        case .pixelBudgetExceeded: "GIF previews are limited to 16,777,216 pixels across all scaled frames."
        case let .mismatchedFrame(index, expected): "Frame \(index) does not hold \(expected) pixels."
        }
    }
}

/// Encodes indexed-color GIF89a animations: global 256-color palette, per-frame delays,
/// optional looping and nearest-neighbor integer scaling. Frame index 0 stays transparent.
public struct GIFWriter {
    public static let maximumDimension = 1024
    public static let maximumFrames = 256
    public static let maximumScale = 16
    static let maximumDecodedPixels = 16_777_216

    public init() {}

    public func encode(
        width: Int,
        height: Int,
        frames: [GIFAnimationFrame],
        palette: [PixelColor],
        scale: Int = 1,
        loops: Bool = true
    ) throws -> Data {
        try Self.validateCanvas(width: width, height: height, frameCount: frames.count, scale: scale)
        let pixelCount = width * height
        for (index, frame) in frames.enumerated() where frame.indices.count != pixelCount {
            throw GIFWritingError.mismatchedFrame(index, expected: pixelCount)
        }

        var data = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]) // "GIF89a"
        let scaledWidth = width * scale
        let scaledHeight = height * scale
        data.append(contentsOf: Self.le16(scaledWidth) + Self.le16(scaledHeight))
        data.append(contentsOf: [0xF7, 0x00, 0x00]) // global 256-color table, 8-bit primaries, background 0
        for index in 0..<256 {
            let color = index < palette.count ? palette[index] : PixelColor(red: 0, green: 0, blue: 0)
            data.append(contentsOf: [color.red, color.green, color.blue])
        }
        if loops {
            data.append(contentsOf: [
                0x21, 0xFF, 0x0B, 0x4E, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45, 0x32, 0x2E, 0x30, // "NETSCAPE2.0"
                0x03, 0x01, 0x00, 0x00, 0x00,
            ])
        }
        for frame in frames {
            // Clear the previous image so transparent pixels in the next frame do not leave a trail.
            let delay = min(max(frame.delayMilliseconds, 20), Int(UInt16.max) * 10)
            data.append(contentsOf: [0x21, 0xF9, 0x04, 0x09] + Self.le16((delay + 5) / 10) + [0x00, 0x00])
            data.append(0x2C)
            data.append(contentsOf: Self.le16(0) + Self.le16(0) + Self.le16(scaledWidth) + Self.le16(scaledHeight))
            data.append(0x00) // no local table, no interlace
            data.append(0x08) // LZW minimum code size for a 256-color table
            let compressed = Self.lzwEncode(Self.scaled(frame.indices, width: width, height: height, scale: scale))
            for block in compressed.chunked(into: 255) {
                data.append(UInt8(block.count))
                data.append(contentsOf: block)
            }
            data.append(0x00)
        }
        data.append(0x3B)
        return data
    }

    /// Checks the preview budget before the caller allocates indexed frames.
    public static func validateCanvas(width: Int, height: Int, frameCount: Int, scale: Int) throws {
        guard (1...Self.maximumDimension).contains(width), (1...Self.maximumDimension).contains(height) else {
            throw GIFWritingError.invalidSize(width: width, height: height)
        }
        guard (1...Self.maximumScale).contains(scale) else { throw GIFWritingError.invalidScale(scale) }
        guard frameCount > 0 else { throw GIFWritingError.emptyAnimation }
        guard frameCount <= Self.maximumFrames else { throw GIFWritingError.tooManyFrames(frameCount) }
        guard width * height <= Self.maximumDecodedPixels / scale / scale / frameCount else {
            throw GIFWritingError.pixelBudgetExceeded
        }
    }

    // MARK: - Scaling

    private static func scaled(_ indices: [UInt8], width: Int, height: Int, scale: Int) -> [UInt8] {
        guard scale > 1 else {
            return indices
        }
        var output = [UInt8](repeating: 0, count: indices.count * scale * scale)
        for y in 0..<(height * scale) {
            let sourceRow = (y / scale) * width
            let row = y * width * scale
            for x in 0..<(width * scale) {
                output[row + x] = indices[sourceRow + x / scale]
            }
        }
        return output
    }

    // MARK: - LZW

    static func lzwEncode(_ indices: [UInt8]) -> [UInt8] {
        guard let first = indices.first.map(Int.init) else {
            return []
        }
        let minimumCodeSize = 8
        let clearCode = 1 << minimumCodeSize
        let endCode = clearCode + 1
        var codeSize = minimumCodeSize + 1
        var nextCode = endCode + 1
        var dictionary: [Int: Int] = [:]
        dictionary.reserveCapacity(4096)
        var output: [UInt8] = []
        var bitBuffer = 0
        var bitCount = 0

        func emit(_ code: Int) {
            bitBuffer |= code << bitCount
            bitCount += codeSize
            while bitCount >= 8 {
                output.append(UInt8(bitBuffer & 0xFF))
                bitBuffer >>= 8
                bitCount -= 8
            }
        }

        emit(clearCode)
        var prefix = first
        for byte in indices.dropFirst() {
            let value = Int(byte)
            let key = (prefix << 8) | value
            if let code = dictionary[key] {
                prefix = code
                continue
            }
            emit(prefix)
            if nextCode == 4096 {
                emit(clearCode)
                dictionary.removeAll(keepingCapacity: true)
                codeSize = minimumCodeSize + 1
                nextCode = endCode + 1
            } else {
                dictionary[key] = nextCode
                nextCode += 1
                if nextCode - 1 == (1 << codeSize) {
                    codeSize += 1
                }
            }
            prefix = value
        }
        emit(prefix)
        emit(endCode)
        if bitCount > 0 {
            output.append(UInt8(bitBuffer & 0xFF))
        }
        return output
    }

    static func le16(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }
}

private extension Array where Element == UInt8 {
    func chunked(into size: Int) -> [SubSequence] {
        var chunks: [SubSequence] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(self[index..<end])
            index = end
        }
        return chunks
    }
}
