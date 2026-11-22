//
//  FontHandle.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/19/23.
//

import AdaRender
import AdaTextShaper
import AtlasFontGenerator
import Foundation
import Synchronization

/// Hold information about font data and atlas.
@safe
final class FontHandle: Hashable, @unchecked Sendable {
    let atlasTexture: Texture2D
    let fontData: OpaquePointer!
    let fontPath: URL?
    private let variationAxes: [FontVariationAxis]
    private let shapingFont = Mutex<ShapingFont?>(nil)

    let metrics: FontMetrics
    let fontName: String
    let geometryScale: Double

    init(
        atlasTexture: Texture2D,
        fontData: OpaquePointer,
        fontPath: URL?,
        variationAxes: [FontVariationAxis] = []
    ) {
        self.atlasTexture = atlasTexture
        unsafe self.fontData = fontData
        self.fontPath = fontPath
        self.variationAxes = variationAxes

        self.metrics = unsafe font_geometry_get_metrics(fontData)
        guard let fontName = unsafe font_geometry_get_name(fontData) else {
            preconditionFailure("Generated font geometry has no name.")
        }
        self.fontName = unsafe String(cString: fontName)
        self.geometryScale = unsafe font_geometry_get_scale(fontData)
    }

    deinit {
        unsafe font_handle_destroy(self.fontData)
    }

    // Fallback atlases can provide glyph geometry without ever opening a shaper.
    func preparedShapingFont() -> ShapingFont? {
        guard let fontPath else {
            return nil
        }
        return shapingFont.withLock { cached in
            if let cached {
                return cached
            }
            let font = ShapingFont(fontPath, variationAxes: variationAxes)
            cached = font
            return font
        }
    }

    func getGlyph(for scalar: UInt32) -> Glyph? {
        guard let glyph = unsafe font_handle_get_glyph_unicode(self.fontData, scalar) else {
            return nil
        }

        return unsafe Glyph(ref: glyph)
    }

    func getGlyph(forGlyphIndex glyphIndex: Int32) -> Glyph? {
        guard let glyph = unsafe font_handle_get_glyph_index(self.fontData, glyphIndex) else {
            return nil
        }

        return unsafe Glyph(ref: glyph)
    }

    func getAdvance(_ advance: inout Double, _ currentUnicode: UInt32, _ nextUnicode: UInt32) {
        unsafe font_handle_get_advance(self.fontData, &advance, currentUnicode, nextUnicode)
    }

    var glyphsCount: Int {
        unsafe Int(font_handle_get_glyphs_count(self.fontData))
    }

    // MARK: Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.fontName)
        hasher.combine(self.geometryScale)
        hasher.combine(self.metrics.underlineThickness)
        hasher.combine(self.metrics.underlineY)
        hasher.combine(self.metrics.emSize)
        hasher.combine(self.metrics.ascenderY)
        hasher.combine(self.metrics.descenderY)
        hasher.combine(self.metrics.lineHeight)
    }

    static func == (lhs: FontHandle, rhs: FontHandle) -> Bool {
        return lhs.fontName == rhs.fontName
            && lhs.geometryScale == rhs.geometryScale
            && lhs.metrics.emSize == rhs.metrics.emSize
            && lhs.metrics.lineHeight == rhs.metrics.lineHeight
            && lhs.metrics.ascenderY == rhs.metrics.ascenderY
            && lhs.metrics.descenderY == rhs.metrics.descenderY
            && lhs.metrics.underlineY == rhs.metrics.underlineY
            && lhs.metrics.underlineThickness == rhs.metrics.underlineThickness
            && lhs.glyphsCount == rhs.glyphsCount
    }
}

extension FontHandle {
    /// Owns one immutable HarfBuzz font. Each caller shapes with its own HarfBuzz buffer.
    @safe
    final class ShapingFont: @unchecked Sendable {
        @unsafe let ref: OpaquePointer

        init?(_ fontPath: URL, variationAxes: [FontVariationAxis]) {
            let axes = variationAxes.map { ada_font_variation_axis_t(tag: $0.tag, value: $0.value) }
            let nativeFont = unsafe fontPath.path.withCString { path in
                unsafe axes.withUnsafeBufferPointer { axes in
                    unsafe ada_shaping_font_create(path, axes.baseAddress, Int32(axes.count))
                }
            }
            guard let nativeFont = unsafe nativeFont else {
                return nil
            }
            unsafe self.ref = nativeFont
        }

        deinit {
            unsafe ada_shaping_font_destroy(ref)
        }
    }

    @safe
    final class Glyph {
        let ref: OpaquePointer

        init(ref: OpaquePointer) {
            unsafe self.ref = ref
        }

        deinit {
            unsafe font_glyph_destroy(self.ref)
        }

        var advance: Double {
            unsafe font_glyph_get_advance(self.ref)
        }

        var glyphIndex: Int32 {
            unsafe Int32(font_glyph_get_index(self.ref))
        }

        func getQuadAtlasBounds(_ l: inout Double, _ b: inout Double, _ r: inout Double, _ t: inout Double) {
            unsafe font_glyph_get_quad_atlas_bounds(self.ref, &l, &b, &r, &t)
        }

        func getQuadPlaneBounds(_ pl: inout Double, _ pb: inout Double, _ pr: inout Double, _ pt: inout Double) {
            unsafe font_glyph_get_quad_plane_bounds(self.ref, &pl, &pb, &pr, &pt)
        }
    }
}
