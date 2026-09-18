//
//  Font.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/4/22.
//

import AdaAssets
import AdaUtils
import AtlasFontGenerator
import Foundation

#if canImport(CoreText)
    import CoreText
#endif

/// Contains font styles.
public enum FontWeight: String {
    case regular
    case bold
    case boldItalic
    case semibold
    case italic
    case light
    case heavy
}

public struct FontVariationAxis: Hashable, Sendable {
    public let tag: UInt32
    public let value: Double

    public init(tag: String, value: Double) {
        self.tag = Self.makeTag(tag)
        self.value = value
    }

    public init(tag: UInt32, value: Double) {
        self.tag = tag
        self.value = value
    }

    public static func weight(_ value: Double) -> Self {
        Self(tag: "wght", value: value)
    }

    public static func italic(_ value: Double = 1) -> Self {
        Self(tag: "ital", value: value)
    }

    public static func slant(_ value: Double) -> Self {
        Self(tag: "slnt", value: value)
    }

    public static func width(_ value: Double) -> Self {
        Self(tag: "wdth", value: value)
    }

    public static func monospaced(_ value: Double = 1) -> Self {
        Self(tag: "MONO", value: value)
    }

    private static func makeTag(_ tag: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in tag.utf8.prefix(4) {
            result = (result << 8) | UInt32(byte)
        }

        let missingBytes = max(0, 4 - tag.utf8.count)
        for _ in 0..<missingBytes {
            result = (result << 8) | 32
        }

        return result
    }
}

public enum FontCharset: Hashable, Sendable {
    case `default`
    case codepoints([UInt32], includeDefault: Bool)
    case text(String, includeDefault: Bool)

    var includeDefaultCharset: Bool {
        switch self {
        case .default:
            return true
        case let .codepoints(_, includeDefault),
            let .text(_, includeDefault):
            return includeDefault
        }
    }

    var additionalCodepoints: [UInt32] {
        switch self {
        case .default:
            return []
        case let .codepoints(codepoints, _):
            return codepoints
        case let .text(text, _):
            return text.unicodeScalars.map(\.value)
        }
    }
}

/// An object that provides access to the font's characteristics.
public final class FontResource: Asset, Hashable, @unchecked Sendable {
    let handle: FontHandle

    init(handle: FontHandle) {
        self.handle = handle
    }

    public var assetMetaInfo: AssetMetaInfo?

    public static func extensions() -> [String] {
        return ["ttf", "otf"]
    }

    public required convenience init(from decoder: AssetDecoder) throws {
        let emSizeStr = decoder.assetMeta.queryParams.first(where: { $0.name == "emSize" })?.value ?? ""
        let emSize = Double(emSizeStr)
        guard let handle = Self.custom(fontPath: decoder.assetMeta.filePath, emFontScale: emSize)?.handle else {
            throw AssetDecodingError.decodingProblem("Font not found at path \(decoder.assetMeta.filePath)")
        }
        self.init(handle: handle)
    }

    public func encodeContents(with _: AssetEncoder) throws {
        fatalErrorMethodNotImplemented()
    }
}

extension FontResource {
    /// Returns font scale for font size.
    public func getFontScale(for size: Double) -> Double {
        return size / self.fontEmSize
    }

    /// The top y-coordinate, offset from the baseline, of the font’s longest ascender.
    public var ascender: Double {
        self.handle.metrics.ascenderY
    }

    /// The bottom y-coordinate, offset from the baseline, of the font’s longest descender.
    public var descender: Double {
        self.handle.metrics.descenderY
    }

    /// The height, in points, of text lines.
    public var lineHeight: Double {
        self.handle.metrics.lineHeight
    }

    // The size of one EM.
    public var fontEmSize: Double {
        self.handle.metrics.emSize
    }
}

extension FontResource {
    public static func == (lhs: FontResource, rhs: FontResource) -> Bool {
        return lhs.handle == rhs.handle
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.handle)
    }
}

extension FontResource {
    private enum Constants {
        static let defaultEmFontScale: Double = 52
    }

    public static func registerPrebuiltAtlasBundle(_ bundle: Bundle, subdirectory: String) {
        FontAtlasGenerator.shared.registerPrebuiltAtlasBundle(bundle, subdirectory: subdirectory)
    }

    public static func prebuiltAtlasFileName(
        fontFileName: String,
        emFontScale: Double,
        includeDefaultCharset: Bool = true,
        additionalCodepoints: [UInt32] = [],
        variations: [FontVariationAxis] = []
    ) -> String {
        let descriptor = FontDescriptor(
            emFontScale: emFontScale,
            includeDefaultCharset: includeDefaultCharset,
            additionalCodepoints: Array(Set(additionalCodepoints)).sorted(),
            variationAxes: normalizedVariationAxes(variations)
        )
        return FontAtlasGenerator.cacheFileName(fontName: fontFileName, fontDescriptor: descriptor)
    }

    public static func prebuildCustomAtlas(
        fontPath: URL,
        emFontScale: Double? = nil,
        includeDefaultCharset: Bool = true,
        additionalCodepoints: [UInt32] = [],
        variations: [FontVariationAxis] = []
    ) -> Bool {
        let descriptor = FontDescriptor(
            emFontScale: emFontScale ?? Constants.defaultEmFontScale,
            includeDefaultCharset: includeDefaultCharset,
            additionalCodepoints: Array(Set(additionalCodepoints)).sorted(),
            variationAxes: normalizedVariationAxes(variations)
        )
        return FontAtlasGenerator.shared.ensureCachedAtlas(fontPath: fontPath, fontDescriptor: descriptor)
    }

    public static func hasPrebuiltAtlas(
        fontPath: URL,
        emFontScale: Double? = nil,
        includeDefaultCharset: Bool = true,
        additionalCodepoints: [UInt32] = [],
        variations: [FontVariationAxis] = []
    ) -> Bool {
        let descriptor = FontDescriptor(
            emFontScale: emFontScale ?? Constants.defaultEmFontScale,
            includeDefaultCharset: includeDefaultCharset,
            additionalCodepoints: Array(Set(additionalCodepoints)).sorted(),
            variationAxes: normalizedVariationAxes(variations)
        )
        return FontAtlasGenerator.shared.hasPrebuiltCachedAtlas(fontPath: fontPath, fontDescriptor: descriptor)
    }

    public static func prebuildSystemAtlas(weight: FontWeight = .regular, emFontScale: Double? = nil) -> Bool {
        let resolvedScale = emFontScale ?? Constants.defaultEmFontScale
        let fontName = "OpenSans-\(weight.fileNameComponent)"
        guard
            let fontPath = Bundle.module.url(
                forResource: fontName,
                withExtension: "ttf",
                subdirectory: "Assets/Fonts/opensans"
            )
        else {
            return false
        }

        return prebuildCustomAtlas(fontPath: fontPath, emFontScale: resolvedScale)
    }

    private struct CacheKey: Hashable {
        let path: String
        let emFontScale: Double
        var includeDefaultCharset: Bool = true
        var additionalCodepoints: [UInt32] = []
        var variationAxes: [FontVariationAxis] = []

        func covers(_ key: Self) -> Bool {
            guard path == key.path && emFontScale == key.emFontScale && variationAxes == key.variationAxes else {
                return false
            }

            guard includeDefaultCharset || !key.includeDefaultCharset else {
                return false
            }

            return Set(additionalCodepoints).isSuperset(of: key.additionalCodepoints)
        }
    }

    private final class CacheStore: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [CacheKey: FontResource] = [:]

        func get(_ key: CacheKey) -> FontResource? {
            lock.lock()
            defer {
                lock.unlock()
            }
            return values[key]
        }

        func getResourceCovering(_ key: CacheKey) -> FontResource? {
            lock.lock()
            defer {
                lock.unlock()
            }

            return values.first { cachedKey, _ in
                cachedKey.covers(key)
            }?
            .value
        }

        func set(_ value: FontResource, for key: CacheKey) {
            lock.lock()
            defer {
                lock.unlock()
            }
            values[key] = value
        }
    }

    private static let cacheStore = CacheStore()

    private static func normalizedVariationAxes(_ axes: [FontVariationAxis]) -> [FontVariationAxis] {
        var valuesByTag: [UInt32: Double] = [:]
        for axis in axes {
            valuesByTag[axis.tag] = axis.value
        }

        return
            valuesByTag
            .map { FontVariationAxis(tag: $0.key, value: $0.value) }
            .sorted { lhs, rhs in
                lhs.tag == rhs.tag ? lhs.value < rhs.value : lhs.tag < rhs.tag
            }
    }

    /// Create custom font from file path.
    /// - Returns: Returns font if font available or null if something went wrong.
    public static func custom(fontPath: URL, emFontScale: Double? = nil) -> FontResource? {
        custom(
            fontPath: fontPath,
            emFontScale: emFontScale,
            includeDefaultCharset: true,
            additionalCodepoints: [],
            variations: []
        )
    }

    public static func custom(
        fontPath: URL,
        emFontScale: Double? = nil,
        includeDefaultCharset: Bool,
        additionalCodepoints: [UInt32],
        variations: [FontVariationAxis] = []
    ) -> FontResource? {
        let resolvedScale = emFontScale ?? Constants.defaultEmFontScale
        let normalizedCodepoints = Array(Set(additionalCodepoints)).sorted()
        let normalizedVariations = normalizedVariationAxes(variations)
        let key = CacheKey(
            path: fontPath.path,
            emFontScale: resolvedScale,
            includeDefaultCharset: includeDefaultCharset,
            additionalCodepoints: normalizedCodepoints,
            variationAxes: normalizedVariations
        )

        if let cached = cacheStore.getResourceCovering(key) {
            return cached
        }

        let descriptor = FontDescriptor(
            emFontScale: resolvedScale,
            includeDefaultCharset: includeDefaultCharset,
            additionalCodepoints: normalizedCodepoints,
            variationAxes: normalizedVariations
        )
        guard let fontHandle = FontAtlasGenerator.shared.generateAtlas(fontPath: fontPath, fontDescriptor: descriptor) else {
            return nil
        }
        let resource = FontResource(handle: fontHandle)
        cacheStore.set(resource, for: key)
        return resource
    }

    public static func dynamic(
        fontPath: URL,
        emFontScale: Double? = nil,
        charset: FontCharset? = nil,
        variations: [FontVariationAxis] = []
    ) -> FontResource? {
        let resolvedCharset = charset ?? .default
        return custom(
            fontPath: fontPath,
            emFontScale: emFontScale,
            includeDefaultCharset: resolvedCharset.includeDefaultCharset,
            additionalCodepoints: resolvedCharset.additionalCodepoints,
            variations: variations
        )
    }

    public static func fallback(for scalar: UnicodeScalar, baseFont: FontResource) -> FontResource? {
        #if canImport(CoreText)
            guard let fontURL = fallbackFontURL(for: scalar, baseFontName: baseFont.handle.fontName) else {
                return nil
            }

            return custom(
                fontPath: fontURL,
                emFontScale: baseFont.fontEmSize,
                includeDefaultCharset: false,
                additionalCodepoints: [scalar.value],
                variations: []
            )
        #else
            return nil
        #endif
    }

    #if canImport(CoreText)
        private static func fallbackFontURL(for scalar: UnicodeScalar, baseFontName: String) -> URL? {
            let character = String(scalar)
            let baseFont = CTFontCreateWithName(baseFontName as CFString, 12, nil)
            let fallbackFont = CTFontCreateForString(
                baseFont,
                character as CFString,
                CFRange(location: 0, length: character.utf16.count)
            )

            guard font(fallbackFont, contains: scalar) else {
                return nil
            }

            return CTFontCopyAttribute(fallbackFont, kCTFontURLAttribute) as? URL
        }

        private static func font(_ font: CTFont, contains scalar: UnicodeScalar) -> Bool {
            let characters = String(scalar).utf16.map { UniChar($0) }
            guard !characters.isEmpty else {
                return false
            }

            var glyphs = Array(repeating: CGGlyph(), count: characters.count)
            let foundGlyphs = characters.withUnsafeBufferPointer { charactersBuffer in
                glyphs.withUnsafeMutableBufferPointer { glyphsBuffer in
                    guard let charactersAddress = charactersBuffer.baseAddress, let glyphsAddress = glyphsBuffer.baseAddress else {
                        return false
                    }
                    return CTFontGetGlyphsForCharacters(
                        font,
                        charactersAddress,
                        glyphsAddress,
                        characters.count
                    )
                }
            }

            return foundGlyphs && glyphs.allSatisfy { $0 != 0 }
        }
    #endif
}

// TODO: Add cache

extension FontResource {
    /// Returns default font from AdaEngine bundle.
    public static func system(weight: FontWeight = .regular, emFontScale: Double? = nil) -> FontResource {
        let resolvedScale = emFontScale ?? Constants.defaultEmFontScale
        let path = "Assets/Fonts/opensans/OpenSans-\(weight.fileNameComponent).ttf"
        let cachePath = "\(path)#emSize=\(resolvedScale)"

        let key = CacheKey(path: cachePath, emFontScale: resolvedScale)
        if let cached = cacheStore.get(key) {
            return cached
        }

        guard let resourceURL = Bundle.module.resourceURL else {
            fatalError("[Font]: Failed to resolve system font bundle")
        }

        let fontPath = resourceURL.appendingPathComponent(path)
        guard let resource = Self.custom(fontPath: fontPath, emFontScale: resolvedScale) else {
            fatalError("[Font]: Failed to load system font resource at path \(fontPath.path)")
        }

        cacheStore.set(resource, for: key)
        return resource
    }
}

extension FontWeight {
    var fileNameComponent: String {
        switch self {
        case .boldItalic:
            return "BoldItalic"
        default:
            return self.rawValue.capitalized
        }
    }
}
