//
//  FontAtlasGenerator.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/5/23.
//

import AdaRender
import AdaUtils
import AtlasFontGenerator
import Foundation
import Logging

/// A font descriptor.
public struct FontDescriptor {
    /// The em font scale.
    public var emFontScale: Double
    var includeDefaultCharset: Bool = true
    var additionalCodepoints: [UInt32] = []
    var variationAxes: [FontVariationAxis] = []
}

/// Generate MTSDF atlas texture from font.
final class FontAtlasGenerator: Sendable {
    static let shared = FontAtlasGenerator()

    /// Distance range encoded in both generated and cached MTSDF atlases.
    /// Keep the text shader's ScreenPxRange in sync with this value.
    static let atlasPixelRange: Double = 4

    private static let cacheMagic: UInt32 = 0x3542_4641
    private static let cacheVersion = 6

    private let logger = Logger(label: "org.adaengine.Font")
    private let prebuiltAtlasLocations = PrebuiltAtlasLocationStore()

    private init() {}

    func registerPrebuiltAtlasBundle(_ bundle: Bundle, subdirectory: String) {
        prebuiltAtlasLocations.append(bundle: bundle, subdirectory: subdirectory)
    }

    static func cacheFileName(fontName: String, fontDescriptor: FontDescriptor) -> String {
        let charsetHash = charsetCacheKey(for: fontDescriptor)
        let variationsHash = variationCacheKey(for: fontDescriptor)
        return "\(fontName)-\(fontDescriptor.emFontScale.rounded())-\(charsetHash)-\(variationsHash)-v\(cacheVersion).fontbin"
    }

    func ensureCachedAtlas(fontPath: URL, fontDescriptor: FontDescriptor) -> Bool {
        let fontName = fontPath.lastPathComponent
        let fileName = Self.cacheFileName(fontName: fontName, fontDescriptor: fontDescriptor)
        if self.getCachedAtlas(by: fileName) != nil {
            return true
        }

        guard let cachedAtlas = self.generateCachedAtlas(fontPath: fontPath, fontDescriptor: fontDescriptor) else {
            return false
        }

        self.saveCachedAtlas(cachedAtlas, fileName: fileName)
        return true
    }

    func hasPrebuiltCachedAtlas(fontPath: URL, fontDescriptor: FontDescriptor) -> Bool {
        let fontName = fontPath.lastPathComponent
        let fileName = Self.cacheFileName(fontName: fontName, fontDescriptor: fontDescriptor)
        return self.getPrebuiltCachedAtlas(by: fileName) != nil
    }

    /// Generate and save to the disk info about font atlas.
    ///
    /// - Parameter fontPath: The path to the font.
    /// - Parameter fontDescriptor: The font descriptor.
    /// - Returns: The font handle.
    func generateAtlas(fontPath: URL, fontDescriptor: FontDescriptor) -> FontHandle? {
        var atlasFontDescriptor = font_atlas_descriptor()
        atlasFontDescriptor.angleThreshold = 3.0
        atlasFontDescriptor.atlasPixelRange = Self.atlasPixelRange
        atlasFontDescriptor.coloringSeed = 3
        atlasFontDescriptor.threads = 8
        atlasFontDescriptor.expensiveColoring = 1
        atlasFontDescriptor.emFontScale = fontDescriptor.emFontScale
        atlasFontDescriptor.atlasImageType = AFG_IMAGE_TYPE_MTSDF
        atlasFontDescriptor.miterLimit = 1.0
        atlasFontDescriptor.includeDefaultCharset = fontDescriptor.includeDefaultCharset ? 1 : 0

        let fontPathString = fontPath.path
        let fontName = fontPath.lastPathComponent
        let fileName = Self.cacheFileName(fontName: fontName, fontDescriptor: fontDescriptor)

        if let cachedAtlas = self.getCachedAtlas(by: fileName),
            let fontData = self.makeCachedFontHandle(from: cachedAtlas) {
            let texture = self.makeTextureAtlas(
                from: cachedAtlas.data,
                width: cachedAtlas.width,
                height: cachedAtlas.height
            )
            return unsafe FontHandle(
                atlasTexture: texture,
                fontData: fontData,
                fontPath: fontPath,
                variationAxes: fontDescriptor.variationAxes
            )
        }

        if let cachedAtlas = self.getPrebuiltCachedAtlas(by: fileName),
            let fontData = self.makeCachedFontHandle(from: cachedAtlas) {
            let texture = self.makeTextureAtlas(
                from: cachedAtlas.data,
                width: cachedAtlas.width,
                height: cachedAtlas.height
            )
            return unsafe FontHandle(
                atlasTexture: texture,
                fontData: fontData,
                fontPath: fontPath,
                variationAxes: fontDescriptor.variationAxes
            )
        }

        let variationTags = fontDescriptor.variationAxes.map(\.tag)
        let variationValues = fontDescriptor.variationAxes.map(\.value)
        guard
            let generator = unsafe fontDescriptor.additionalCodepoints.withUnsafeBufferPointer({ codepoints in
                unsafe variationTags.withUnsafeBufferPointer { tags in
                    unsafe variationValues.withUnsafeBufferPointer { values in
                        atlasFontDescriptor.additionalCodepoints = codepoints.baseAddress
                        atlasFontDescriptor.additionalCodepointsCount = Int32(codepoints.count)
                        atlasFontDescriptor.variationAxisTags = tags.baseAddress
                        atlasFontDescriptor.variationAxisValues = values.baseAddress
                        atlasFontDescriptor.variationAxesCount = Int32(tags.count)

                        return unsafe fontPathString.withCString { fontPathPtr in
                            unsafe fontName.withCString { fontNamePtr in
                                unsafe font_atlas_generator_create(fontPathPtr, fontNamePtr, atlasFontDescriptor)
                            }
                        }
                    }
                }
            })
        else {
            return nil
        }

        defer {
            unsafe font_atlas_generator_destroy(generator)
        }

        guard let fontData = unsafe font_atlas_generator_get_font_data(generator) else {
            return nil
        }

        guard let bitmap = unsafe font_atlas_generator_generate_bitmap(generator) else {
            return nil
        }

        defer {
            unsafe font_atlas_bitmap_destroy(bitmap)
        }

        let bitmapValue = unsafe bitmap.pointee
        guard let pixels = unsafe bitmapValue.pixels else {
            return nil
        }
        let data = unsafe Data(bytes: pixels, count: Int(bitmapValue.pixelsCount))

        let width = unsafe Int(bitmapValue.bitmapWidth)
        let height = unsafe Int(bitmapValue.bitmapHeight)

        assert(width > 0, "Invalid width of atlas")
        assert(height > 0, "Invalid width of atlas")

        if let cachedAtlas = self.makeCachedAtlas(
            data: data,
            width: width,
            height: height,
            fontData: fontData
        ) {
            self.saveCachedAtlas(cachedAtlas, fileName: fileName)
        }

        let texture = self.makeTextureAtlas(from: data, width: width, height: height)
        return unsafe FontHandle(
            atlasTexture: texture,
            fontData: fontData,
            fontPath: fontPath,
            variationAxes: fontDescriptor.variationAxes
        )
    }

    // MARK: - Private

    private func makeTextureAtlas(from data: Data, width: Int, height: Int) -> Texture2D {
        let image = Image(
            width: width,
            height: height,
            data: data
        )

        var textSamplerDesc = SamplerDescriptor()
        textSamplerDesc.magFilter = .linear
        textSamplerDesc.mipFilter = .notMipmapped
        textSamplerDesc.minFilter = .linear

        let descriptor = TextureDescriptor(
            width: width,
            height: height,
            pixelFormat: .rgba_32f,
            textureUsage: [.read],
            textureType: .texture2D,
            mipmapLevel: 0,
            image: image,
            samplerDescription: textSamplerDesc
        )

        return Texture2D(descriptor: descriptor)
    }

    private func makeAtlasDescriptor(from fontDescriptor: FontDescriptor) -> font_atlas_descriptor {
        var atlasFontDescriptor = font_atlas_descriptor()
        atlasFontDescriptor.angleThreshold = 3.0
        atlasFontDescriptor.atlasPixelRange = Self.atlasPixelRange
        atlasFontDescriptor.coloringSeed = 3
        atlasFontDescriptor.threads = 8
        atlasFontDescriptor.expensiveColoring = 1
        atlasFontDescriptor.emFontScale = fontDescriptor.emFontScale
        atlasFontDescriptor.atlasImageType = AFG_IMAGE_TYPE_MTSDF
        atlasFontDescriptor.miterLimit = 1.0
        atlasFontDescriptor.includeDefaultCharset = fontDescriptor.includeDefaultCharset ? 1 : 0
        return atlasFontDescriptor
    }

    private func generateCachedAtlas(fontPath: URL, fontDescriptor: FontDescriptor) -> CachedFontAtlas? {
        var atlasFontDescriptor = makeAtlasDescriptor(from: fontDescriptor)
        let fontPathString = fontPath.path
        let fontName = fontPath.lastPathComponent

        let variationTags = fontDescriptor.variationAxes.map(\.tag)
        let variationValues = fontDescriptor.variationAxes.map(\.value)
        guard
            let generator = unsafe fontDescriptor.additionalCodepoints.withUnsafeBufferPointer({ codepoints in
                unsafe variationTags.withUnsafeBufferPointer { tags in
                    unsafe variationValues.withUnsafeBufferPointer { values in
                        atlasFontDescriptor.additionalCodepoints = codepoints.baseAddress
                        atlasFontDescriptor.additionalCodepointsCount = Int32(codepoints.count)
                        atlasFontDescriptor.variationAxisTags = tags.baseAddress
                        atlasFontDescriptor.variationAxisValues = values.baseAddress
                        atlasFontDescriptor.variationAxesCount = Int32(tags.count)

                        return unsafe fontPathString.withCString { fontPathPtr in
                            unsafe fontName.withCString { fontNamePtr in
                                unsafe font_atlas_generator_create(fontPathPtr, fontNamePtr, atlasFontDescriptor)
                            }
                        }
                    }
                }
            })
        else {
            return nil
        }

        defer {
            unsafe font_atlas_generator_destroy(generator)
        }

        guard
            let fontData = unsafe font_atlas_generator_get_font_data(generator),
            let bitmap = unsafe font_atlas_generator_generate_bitmap(generator)
        else {
            return nil
        }

        defer {
            unsafe font_atlas_bitmap_destroy(bitmap)
        }

        let bitmapValue = unsafe bitmap.pointee
        guard let pixels = unsafe bitmapValue.pixels else {
            return nil
        }
        let data = unsafe Data(bytes: pixels, count: Int(bitmapValue.pixelsCount))
        let width = unsafe Int(bitmapValue.bitmapWidth)
        let height = unsafe Int(bitmapValue.bitmapHeight)

        guard width > 0, height > 0 else {
            return nil
        }

        return makeCachedAtlas(data: data, width: width, height: height, fontData: fontData)
    }

    private static func charsetCacheKey(for descriptor: FontDescriptor) -> String {
        if descriptor.includeDefaultCharset && descriptor.additionalCodepoints.isEmpty {
            return "default"
        }

        let sortedCodepoints = descriptor.additionalCodepoints.sorted()
        let mode = descriptor.includeDefaultCharset ? "default" : "custom"
        return "\(mode)-\(sortedCodepoints.count)-\(fnv1a64Hex(for: sortedCodepoints))"
    }

    private static func variationCacheKey(for descriptor: FontDescriptor) -> String {
        guard !descriptor.variationAxes.isEmpty else {
            return "default"
        }

        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for axis in descriptor.variationAxes {
            var tag = axis.tag.littleEndian
            unsafe withUnsafeBytes(of: &tag) { bytes in
                for byte in bytes {
                    hash ^= UInt64(byte)
                    hash &*= 0x100_0000_01b3
                }
            }

            var value = axis.value.bitPattern.littleEndian
            unsafe withUnsafeBytes(of: &value) { bytes in
                for byte in bytes {
                    hash ^= UInt64(byte)
                    hash &*= 0x100_0000_01b3
                }
            }
        }

        return "var-\(descriptor.variationAxes.count)-\(String(format: "%016llx", hash))"
    }

    private static func fnv1a64Hex(for values: [UInt32]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for value in values {
            var littleEndianValue = value.littleEndian
            unsafe withUnsafeBytes(of: &littleEndianValue) { bytes in
                for byte in bytes {
                    hash ^= UInt64(byte)
                    hash &*= 0x100_0000_01b3
                }
            }
        }
        return String(format: "%016llx", hash)
    }

    private func getCacheDirectory() throws -> URL {
        return try FileSystem.current.url(for: .cachesDirectory)
            .appendingPathComponent("AdaEngine")
            .appendingPathComponent("FontGeneratedAtlases")
    }

    private func createCacheDirectoryIfNeeded() {
        do {
            let cacheDir = try getCacheDirectory()

            if FileSystem.current.itemExists(at: cacheDir) {
                return
            }

            return try FileSystem.current.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        } catch {
            fatalError("[FontAtlasGenerator] \(error)")
        }
    }

    private func makeCachedAtlas(data: Data, width: Int, height: Int, fontData: OpaquePointer) -> CachedFontAtlas? {
        let glyphsCount = unsafe Int(font_handle_get_glyphs_count(fontData))
        guard glyphsCount > 0 else {
            return nil
        }

        var glyphs: [FontCachedGlyph] = []
        glyphs.reserveCapacity(glyphsCount)
        for index in 0..<glyphsCount {
            var glyph = FontCachedGlyph()
            if unsafe font_handle_copy_cached_glyph(fontData, CUnsignedLong(index), &glyph) != 0 {
                glyphs.append(glyph)
            }
        }

        guard !glyphs.isEmpty else {
            return nil
        }

        let kerningsCount = unsafe Int(font_handle_get_kerning_count(fontData))
        var kernings: [FontCachedKerning] = []
        kernings.reserveCapacity(kerningsCount)
        for index in 0..<kerningsCount {
            var kerning = FontCachedKerning()
            if unsafe font_handle_copy_cached_kerning(fontData, CUnsignedLong(index), &kerning) != 0 {
                kernings.append(kerning)
            }
        }

        guard let fontName = unsafe font_geometry_get_name(fontData) else {
            return nil
        }
        return CachedFontAtlas(
            width: width,
            height: height,
            data: data,
            metrics: unsafe font_geometry_get_metrics(fontData),
            geometryScale: unsafe font_geometry_get_scale(fontData),
            fontName: unsafe String(cString: fontName),
            glyphs: glyphs,
            kernings: kernings
        )
    }

    private func makeCachedFontHandle(from atlas: CachedFontAtlas) -> OpaquePointer? {
        atlas.glyphs.withUnsafeBufferPointer { glyphs in
            atlas.kernings.withUnsafeBufferPointer { kernings in
                atlas.fontName.withCString { fontName in
                    unsafe font_handle_create_cached(
                        fontName,
                        atlas.geometryScale,
                        atlas.metrics,
                        glyphs.baseAddress,
                        CUnsignedLong(glyphs.count),
                        kernings.baseAddress,
                        CUnsignedLong(kernings.count)
                    )
                }
            }
        }
    }

    private func saveCachedAtlas(_ atlas: CachedFontAtlas, fileName: String) {
        self.createCacheDirectoryIfNeeded()

        do {
            let file = try self.getCacheDirectory().appendingPathComponent(fileName)
            guard !FileSystem.current.itemExists(at: file) else {
                return
            }

            #if WASM
                try self.encodeCachedAtlas(atlas).write(to: file)
            #else
                try self.encodeCachedAtlas(atlas).write(to: file, options: .atomic)
            #endif
        } catch {
            logger.error("\(error)")
        }
    }

    private func getCachedAtlas(by fileName: String) -> CachedFontAtlas? {
        self.createCacheDirectoryIfNeeded()

        do {
            let file = try self.getCacheDirectory().appendingPathComponent(fileName)

            guard FileSystem.current.itemExists(at: file) else {
                return nil
            }

            let data = try Data(contentsOf: file)
            return self.decodeCachedAtlas(data)
        } catch {
            logger.error("\(error)")
            return nil
        }
    }

    private func getPrebuiltCachedAtlas(by fileName: String) -> CachedFontAtlas? {
        let resourceURL = URL(fileURLWithPath: fileName)
        let resourceName = resourceURL.deletingPathExtension().lastPathComponent
        let resourceExtension = resourceURL.pathExtension

        for location in prebuiltAtlasLocations.values() {
            guard
                let file = location.bundle.url(
                    forResource: resourceName,
                    withExtension: resourceExtension,
                    subdirectory: location.subdirectory
                )
            else {
                continue
            }

            do {
                let data = try Data(contentsOf: file)
                if let atlas = self.decodeCachedAtlas(data) {
                    return atlas
                }
            } catch {
                logger.error("\(error)")
            }
        }

        return nil
    }

    private func encodeCachedAtlas(_ atlas: CachedFontAtlas) -> Data {
        let fontNameData = Data(atlas.fontName.utf8)
        var result = Data()
        result.reserveCapacity(
            128
                + fontNameData.count
                + atlas.glyphs.count * 92
                + atlas.kernings.count * 16
                + atlas.data.count
        )

        result.appendUInt32(Self.cacheMagic)
        result.appendUInt32(UInt32(Self.cacheVersion))
        result.appendUInt32(UInt32(atlas.width))
        result.appendUInt32(UInt32(atlas.height))
        result.appendUInt64(UInt64(atlas.data.count))
        result.appendDouble(atlas.metrics.emSize)
        result.appendDouble(atlas.metrics.ascenderY)
        result.appendDouble(atlas.metrics.descenderY)
        result.appendDouble(atlas.metrics.lineHeight)
        result.appendDouble(atlas.metrics.underlineY)
        result.appendDouble(atlas.metrics.underlineThickness)
        result.appendDouble(atlas.geometryScale)
        result.appendUInt32(UInt32(fontNameData.count))
        result.appendUInt32(UInt32(atlas.glyphs.count))
        result.appendUInt32(UInt32(atlas.kernings.count))
        result.append(fontNameData)

        for glyph in atlas.glyphs {
            result.appendUInt32(glyph.codepoint)
            result.appendInt32(Int32(glyph.glyphIndex))
            result.appendDouble(glyph.advance)
            result.appendDouble(glyph.atlasLeft)
            result.appendDouble(glyph.atlasBottom)
            result.appendDouble(glyph.atlasRight)
            result.appendDouble(glyph.atlasTop)
            result.appendDouble(glyph.planeLeft)
            result.appendDouble(glyph.planeBottom)
            result.appendDouble(glyph.planeRight)
            result.appendDouble(glyph.planeTop)
        }

        for kerning in atlas.kernings {
            result.appendUInt32(kerning.currentUnicode)
            result.appendUInt32(kerning.nextUnicode)
            result.appendDouble(kerning.advanceDelta)
        }

        result.append(atlas.data)
        return result
    }

    private func decodeCachedAtlas(_ data: Data) -> CachedFontAtlas? {
        var reader = FontCacheBinaryReader(data: data)

        guard
            reader.readUInt32() == Self.cacheMagic,
            reader.readUInt32() == UInt32(Self.cacheVersion),
            let width = reader.readUInt32(),
            let height = reader.readUInt32(),
            let atlasDataSize = reader.readUInt64()
        else {
            return nil
        }

        var metrics = FontMetrics()
        guard
            let emSize = reader.readDouble(),
            let ascenderY = reader.readDouble(),
            let descenderY = reader.readDouble(),
            let lineHeight = reader.readDouble(),
            let underlineY = reader.readDouble(),
            let underlineThickness = reader.readDouble(),
            let geometryScale = reader.readDouble(),
            let fontNameLength = reader.readUInt32(),
            let glyphsCount = reader.readUInt32(),
            let kerningsCount = reader.readUInt32()
        else {
            return nil
        }

        metrics.emSize = emSize
        metrics.ascenderY = ascenderY
        metrics.descenderY = descenderY
        metrics.lineHeight = lineHeight
        metrics.underlineY = underlineY
        metrics.underlineThickness = underlineThickness

        guard
            let fontNameData = reader.readData(count: Int(fontNameLength)),
            let fontName = String(bytes: fontNameData, encoding: .utf8)
        else {
            return nil
        }

        var glyphs: [FontCachedGlyph] = []
        glyphs.reserveCapacity(Int(glyphsCount))
        for _ in 0..<glyphsCount {
            var glyph = FontCachedGlyph()
            guard
                let codepoint = reader.readUInt32(),
                let glyphIndex = reader.readInt32(),
                let advance = reader.readDouble(),
                let atlasLeft = reader.readDouble(),
                let atlasBottom = reader.readDouble(),
                let atlasRight = reader.readDouble(),
                let atlasTop = reader.readDouble(),
                let planeLeft = reader.readDouble(),
                let planeBottom = reader.readDouble(),
                let planeRight = reader.readDouble(),
                let planeTop = reader.readDouble()
            else {
                return nil
            }
            glyph.codepoint = codepoint
            glyph.glyphIndex = glyphIndex
            glyph.advance = advance
            glyph.atlasLeft = atlasLeft
            glyph.atlasBottom = atlasBottom
            glyph.atlasRight = atlasRight
            glyph.atlasTop = atlasTop
            glyph.planeLeft = planeLeft
            glyph.planeBottom = planeBottom
            glyph.planeRight = planeRight
            glyph.planeTop = planeTop
            glyphs.append(glyph)
        }

        var kernings: [FontCachedKerning] = []
        kernings.reserveCapacity(Int(kerningsCount))
        for _ in 0..<kerningsCount {
            var kerning = FontCachedKerning()
            guard
                let currentUnicode = reader.readUInt32(),
                let nextUnicode = reader.readUInt32(),
                let advanceDelta = reader.readDouble()
            else {
                return nil
            }
            kerning.currentUnicode = currentUnicode
            kerning.nextUnicode = nextUnicode
            kerning.advanceDelta = advanceDelta
            kernings.append(kerning)
        }

        guard
            let atlasData = reader.readData(count: Int(atlasDataSize)),
            reader.isAtEnd,
            width > 0,
            height > 0,
            !glyphs.isEmpty
        else {
            return nil
        }

        return CachedFontAtlas(
            width: Int(width),
            height: Int(height),
            data: atlasData,
            metrics: metrics,
            geometryScale: geometryScale,
            fontName: fontName,
            glyphs: glyphs,
            kernings: kernings
        )
    }

    private struct CachedFontAtlas {
        let width: Int
        let height: Int
        let data: Data
        let metrics: FontMetrics
        let geometryScale: Double
        let fontName: String
        let glyphs: [FontCachedGlyph]
        let kernings: [FontCachedKerning]
    }
}

private struct PrebuiltAtlasLocation {
    let bundle: Bundle
    let subdirectory: String
}

private final class PrebuiltAtlasLocationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var locations: [PrebuiltAtlasLocation] = []

    func append(bundle: Bundle, subdirectory: String) {
        let normalizedSubdirectory = subdirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let location = PrebuiltAtlasLocation(bundle: bundle, subdirectory: normalizedSubdirectory)
        lock.lock()
        defer {
            lock.unlock()
        }

        let alreadyRegistered = locations.contains { existing in
            existing.bundle.bundleURL == bundle.bundleURL
                && existing.subdirectory == normalizedSubdirectory
        }
        if !alreadyRegistered {
            locations.append(location)
        }
    }

    func values() -> [PrebuiltAtlasLocation] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return locations
    }
}

extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var value = value.littleEndian
        unsafe Swift.withUnsafeBytes(of: &value) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendInt32(_ value: Int32) {
        var value = value.littleEndian
        unsafe Swift.withUnsafeBytes(of: &value) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendUInt64(_ value: UInt64) {
        var value = value.littleEndian
        unsafe Swift.withUnsafeBytes(of: &value) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendDouble(_ value: Double) {
        appendUInt64(value.bitPattern)
    }
}

private struct FontCacheBinaryReader {
    let data: Data
    var offset: Int = 0

    var isAtEnd: Bool {
        offset == data.count
    }

    mutating func readUInt32() -> UInt32? {
        readFixedWidthInteger(UInt32.self)
    }

    mutating func readInt32() -> Int32? {
        readFixedWidthInteger(Int32.self)
    }

    mutating func readUInt64() -> UInt64? {
        readFixedWidthInteger(UInt64.self)
    }

    mutating func readDouble() -> Double? {
        guard let bitPattern = readUInt64() else {
            return nil
        }
        return Double(bitPattern: bitPattern)
    }

    mutating func readData(count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else {
            return nil
        }
        defer {
            offset += count
        }
        return data.subdata(in: offset..<(offset + count))
    }

    private mutating func readFixedWidthInteger<T: FixedWidthInteger>(_: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else {
            return nil
        }

        let value = unsafe data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        offset += size
        return T(littleEndian: value)
    }
}
