//
//  PixelPaletteExtractor.swift
//  AdaEngine
//

import Foundation

/// Extracts a dominant-color palette from RGBA pixels, for user-supplied palette reference images.
///
/// Exact colors are returned when the image uses few enough of them; otherwise pixels are
/// bucketed to 5 bits per channel and the most popular buckets averaged back to RGB.
public enum PixelPaletteExtractor {
    public static let defaultMaximumColors = 16
    public static let maximumColors = 64

    /// - Parameters:
    ///   - rgba: RGBA bytes, four per pixel.
    ///   - maximumColors: palette size cap, clamped to 1...``maximumColors``.
    /// - Returns: dominant opaque colors, most frequent first. Empty for fully transparent input.
    public static func extract(rgba: [UInt8], maximumColors: Int = defaultMaximumColors) -> [PixelColor] {
        let limit = min(max(maximumColors, 1), Self.maximumColors)
        var exact: [UInt32: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        exact.reserveCapacity(1024)
        for offset in stride(from: 0, to: rgba.count - rgba.count % 4, by: 4) where rgba[offset + 3] >= 128 {
            let key = UInt32(rgba[offset]) << 16 | UInt32(rgba[offset + 1]) << 8 | UInt32(rgba[offset + 2])
            let entry = exact[key] ?? (0, 0, 0, 0)
            exact[key] = (entry.count + 1, Int(rgba[offset]), Int(rgba[offset + 1]), Int(rgba[offset + 2]))
        }
        guard !exact.isEmpty else {
            return []
        }
        if exact.count <= limit {
            return exact.values
                .sorted { ($0.count, $0.red, $0.green, $0.blue) > ($1.count, $1.red, $1.green, $1.blue) }
                .map { PixelColor(red: UInt8($0.red), green: UInt8($0.green), blue: UInt8($0.blue)) }
        }
        var buckets: [UInt32: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        buckets.reserveCapacity(4096)
        for entry in exact.values {
            let bucket = UInt32(entry.red >> 3) << 10 | UInt32(entry.green >> 3) << 5 | UInt32(entry.blue >> 3)
            let merged = buckets[bucket] ?? (0, 0, 0, 0)
            buckets[bucket] = (
                merged.count + entry.count,
                merged.red + entry.red * entry.count,
                merged.green + entry.green * entry.count,
                merged.blue + entry.blue * entry.count
            )
        }
        return buckets
            .sorted { ($0.value.count, $0.key) > ($1.value.count, $1.key) }
            .prefix(limit)
            .map { _, entry in
                PixelColor(
                    red: UInt8(entry.red / entry.count),
                    green: UInt8(entry.green / entry.count),
                    blue: UInt8(entry.blue / entry.count)
                )
            }
    }
}
