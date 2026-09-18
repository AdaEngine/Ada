//
//  AtlasRegion.swift
//  AdaEngine
//

import AdaAssets
import Foundation
import Math

/// Describes one named sub-rectangle inside a ``NamedTextureAtlas``.
public struct AtlasRegion: Codable, Sendable, Hashable {
    public var key: String

    /// Top-left of the packed allocation in atlas pixels (includes extrude padding).
    public var atlasOrigin: PointInt

    /// Packed width and height in atlas pixels (includes extrude on both sides).
    public var atlasSize: SizeInt

    /// UV bounds for sampling the **logical** sprite (original pixels), normalized to full atlas size.
    public var uvMin: Vector2

    public var uvMax: Vector2

    /// Original source image dimensions in pixels.
    public var originalSize: SizeInt

    /// Top-left of the original RGBA pixels inside the atlas (absolute pixel coordinates).
    public var contentOriginInAtlas: PointInt

    public init(
        key: String,
        atlasOrigin: PointInt,
        atlasSize: SizeInt,
        uvMin: Vector2,
        uvMax: Vector2,
        originalSize: SizeInt,
        contentOriginInAtlas: PointInt
    ) {
        self.key = key
        self.atlasOrigin = atlasOrigin
        self.atlasSize = atlasSize
        self.uvMin = uvMin
        self.uvMax = uvMax
        self.originalSize = originalSize
        self.contentOriginInAtlas = contentOriginInAtlas
    }
}
