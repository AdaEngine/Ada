/// Normalized point fixed to the entity origin: the center is (0, 0), and positive Y points up.
/// Values outside the sprite are allowed. Image flips do not change this point.
public struct SpriteAnchor: Codable, Hashable, Sendable {
    public var x: Float
    public var y: Float

    public init(x: Float = 0, y: Float = 0) {
        self.x = x
        self.y = y
    }

    public static let center = Self()
    public static let bottomLeft = Self(x: -0.5, y: -0.5)
    public static let bottomCenter = Self(x: 0, y: -0.5)
    public static let bottomRight = Self(x: 0.5, y: -0.5)
    public static let centerLeft = Self(x: -0.5, y: 0)
    public static let centerRight = Self(x: 0.5, y: 0)
    public static let topLeft = Self(x: -0.5, y: 0.5)
    public static let topCenter = Self(x: 0, y: 0.5)
    public static let topRight = Self(x: 0.5, y: 0.5)
}

/// Fixed nine-slice borders in source pixels, including when the source is an atlas slice.
public struct SpriteSliceBorder: Codable, Hashable, Sendable {
    public var top: Float
    public var left: Float
    public var bottom: Float
    public var right: Float

    public init(top: Float = 0, left: Float = 0, bottom: Float = 0, right: Float = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public init(_ value: Float) {
        self.init(top: value, left: value, bottom: value, right: value)
    }
}

/// How an image fills the sprite's size. Fit/fill align the image to the center.
public enum SpriteImageMode: Codable, Hashable, Sendable {
    /// Stretch the whole image to the sprite size (the backward-compatible default).
    case stretch
    /// Preserve aspect ratio and leave space along the remaining axis.
    case fit
    /// Preserve aspect ratio and crop the image to cover the sprite size.
    case fill
    /// Preserve source-pixel corner sizes, stretching the edges and center.
    /// Opposing borders shrink proportionally if the sprite is too small.
    case sliced(SpriteSliceBorder)
    /// Repeat selected axes, starting at the bottom left and clipping partial tiles.
    /// Scale is world units per source pixel; untiled axes stretch once.
    /// Invalid scale emits no geometry. More than 16,384 quads falls back to stretch.
    case tiled(tileX: Bool = true, tileY: Bool = true, scale: Float = 1)
}
