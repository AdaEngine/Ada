//
//  Font.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 09.06.2024.
//

import Foundation

/// A font asset.
public struct Font: Hashable, Equatable, Sendable {
    /// The name of the font.
    public let name: String
    /// The family of the font.
    public let familyFont: String
    /// The point size of the font.
    public var pointSize: Double
    /// The font resource.
    let fontResource: FontResource

    public init(fontResource: FontResource, pointSize: Double) {
        self.pointSize = pointSize
        self.fontResource = fontResource
        self.name = fontResource.handle.fontName

        self.familyFont = ""
    }
}

extension Font {
    /// Create a font from the system resources.
    ///
    /// - Parameter size: The size of the font.
    /// - Returns: The system font.
    public static func system(size: Double) -> Font {
        system(size: size, weight: .regular)
    }

    /// Create a font from the system resources.
    ///
    /// - Parameters:
    ///   - size: The size of the font.
    ///   - weight: The weight of the font.
    /// - Returns: The system font.
    public static func system(size: Double, weight: FontWeight) -> Font {
        let resource = FontResource.system(weight: weight, emFontScale: 74)
        return Font(fontResource: resource, pointSize: size)
    }

    /// A platform monospace font for code, with a bundled-font fallback.
    public static func monospaced(size: Double) -> Font {
        #if os(Windows)
        let root = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:/Windows"
        let paths = [root + "/Fonts/consola.ttf"]
        #elseif os(macOS)
        let paths = ["/System/Library/Fonts/Menlo.ttc"]
        #elseif os(Linux)
        let paths = ["/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", "/usr/share/fonts/truetype/liberation2/LiberationMono-Regular.ttf"]
        #else
        let paths: [String] = []
        #endif
        for path in paths where FileManager.default.fileExists(atPath: path) {
            if let resource = FontResource.custom(fontPath: URL(fileURLWithPath: path)) {
                return Font(fontResource: resource, pointSize: size)
            }
        }
        return .system(size: size, weight: .semibold)
    }

    public static func dynamic(
        fontPath: URL,
        size: Double,
        emFontScale: Double? = nil,
        charset: FontCharset? = nil,
        variations: [FontVariationAxis] = []
    ) -> Font? {
        guard
            let resource = FontResource.dynamic(
                fontPath: fontPath,
                emFontScale: emFontScale,
                charset: charset,
                variations: variations
            )
        else {
            return nil
        }

        return Font(fontResource: resource, pointSize: size)
    }

    /// Returns a copy of this font with semantic text traits applied.
    public func applyingTraits(_ traits: TextFontTraits, scale: Double = 1) -> Font {
        if traits.contains(.code) { return .monospaced(size: pointSize * scale) }
        guard !traits.isEmpty else {
            var font = self
            font.pointSize *= scale
            return font
        }

        let weight: FontWeight
        if traits.contains(.strong) && traits.contains(.emphasis) {
            weight = .boldItalic
        } else if traits.contains(.strong) {
            weight = .bold
        } else if traits.contains(.emphasis) {
            weight = .italic
        } else if traits.contains(.code) {
            weight = .semibold
        } else {
            weight = .regular
        }

        return Self.system(size: self.pointSize * scale, weight: weight)
    }
}

extension Font {
    /// The top y-coordinate, offset from the baseline, of the font’s longest ascender.
    public var ascender: Double {
        return self.fontResource.ascender * pointSize / self.fontResource.fontEmSize
    }

    /// The bottom y-coordinate, offset from the baseline, of the font’s longest descender.
    public var descender: Double {
        return self.fontResource.descender * pointSize / self.fontResource.fontEmSize
    }

    /// The height, in points, of text lines.
    public var lineHeight: Double {
        return self.fontResource.lineHeight * pointSize / self.fontResource.fontEmSize
    }
}

extension Font {
    public struct Weight: Equatable, Hashable, Sendable {
        internal let wightValue: Float

        public static let black: Weight = Self(wightValue: 900)
        public static let bold: Weight = Self(wightValue: 300)
        public static let heavy: Weight = Self(wightValue: 300)
        public static let light: Weight = Self(wightValue: 300)
        public static let medium: Weight = Self(wightValue: 300)
        public static let regular: Weight = Self(wightValue: 500)
        public static let semibold: Weight = Self(wightValue: 300)
        public static let thin: Weight = Self(wightValue: 300)
        public static let ultraLight: Weight = Self(wightValue: 300)
    }
}
