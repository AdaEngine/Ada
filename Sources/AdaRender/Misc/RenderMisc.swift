//
//  RenderMisc.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/18/23.
//

// MARK: - Blending -

/// The source and destination blend factors are often needed to complete specification of a blend operation.
public enum BlendFactor: UInt, Codable, Sendable {
    /// Blend factor of zero.
    ///
    /// F(rgb) = 0
    ///
    /// F(a) = 0
    case zero

    /// Blend factor of one.
    ///
    /// F(rgb) = 1
    ///
    /// F(a) = 1
    case one

    /// Blend factor of source values.
    ///
    /// F(rgb) = Source.rgb
    ///
    /// F(a) = Source.a
    case sourceColor

    /// Blend factor of one minus source values.
    ///
    /// F(rgb) = 1 - Source.rgb
    ///
    /// F(a) = 1 - Source.a
    case oneMinusSourceColor

    /// Blend factor of source alpha.
    ///
    /// F = Source.a
    case sourceAlpha

    /// Blend factor of one minus source alpha.
    ///
    /// F = 1 - Source.a
    case oneMinusSourceAlpha

    /// Blend factor of destination values.
    ///
    /// F(rgb) = Dest.rgb
    ///
    /// F(a) = Dest.a
    case destinationColor

    /// Blend factor of one minus destination values.
    ///
    /// F(rgb) = 1 - Dest.rgb
    ///
    /// F(a) = 1 - Dest.a
    case oneMinusDestinationColor

    /// Blend factor of destination alpha.
    ///
    /// F = Dest.a
    case destinationAlpha

    /// Blend factor of one minus destination alpha.
    ///
    /// F = 1 - Dest.a
    case oneMinusDestinationAlpha

    /// Blend factor of the minimum of either source alpha or one minus destination alpha.
    ///
    /// F(rgb) = min(Source.a, 1 - Dest.a)
    ///
    /// F(a) = 1
    case sourceAlphaSaturated

    /// Blend factor of RGB values.
    ///
    /// F = rgb
    case blendColor

    /// Blend factor of one minus RGB values.
    ///
    /// F = 1 - rgb
    case oneMinusBlendColor

    /// Blend factor of alpha value.
    ///
    /// F = a
    case blendAlpha

    /// Blend factor of one minus alpha value.
    ///
    /// F = 1 - a
    case oneMinusBlendAlpha
}

/// For every pixel, ``BlendOperation`` determines how to combine and weight the source fragment values with the destination values.
/// Some blend operations multiply the source values by a source blend factor (SBF),
/// multiply the destination values by a destination blend factor (DBF), and then combine the results using addition or subtraction.
/// Other blend operations use either a minimum or maximum function to determine the result.
public enum BlendOperation: UInt, Codable, Sendable {
    /// Add portions of both source and destination pixel values.
    ///
    /// RGB = Source.rgb * SBF + Dest.rgb * DBF
    ///
    /// A = Source.a * SBF + Dest.a * DBF
    case add

    /// Subtract a portion of the destination pixel values from a portion of the source.
    ///
    /// RGB = Source.rgb * SBF - Dest.rgb * DBF
    ///
    /// A = Source.a * SBF - Dest.a * DBF
    case subtract

    /// Subtract a portion of the source values from a portion of the destination pixel values.
    ///
    /// RGB = Dest.rgb * DBF - Source.rgb * SBF
    ///
    /// A = Dest.a * DBF - Source.a * SBF
    case reverseSubtract

    /// Minimum of the source and destination pixel values.
    ///
    /// RGB = min(Source.rgb, Dest.rgb)
    ///
    /// A = min(Source.a, Dest.a)
    case min

    /// Maximum of the source and destination pixel values.
    ///
    /// RGB = max(Source.rgb, Dest.rgb)
    ///
    /// A = max(Source.a, Dest.a)
    case max
}

// MARK: - Depth & Stencil -

/// The operation performed on a currently stored stencil value when a comparison test passes or fails.
public enum StencilOperation: UInt, Codable, Sendable {
    /// Set the stencil value to zero.
    case zero

    /// Keep the current stencil value.
    case keep

    /// Replace the stencil reference value.
    /// - WARNING: Currently not supported.
    case replace

    /// If the current stencil value is not the maximum representable value, increase the stencil value by one.
    /// Otherwise, if the current stencil value is the maximum representable value, do not change the stencil value.
    case incrementAndClamp

    /// If the current stencil value is not zero, decrease the stencil value by one. Otherwise, if the current stencil value is zero, do not change the stencil value.
    case decrementAndClamp

    /// Perform a logical bitwise invert operation on the current stencil value.
    case invert

    /// If the current stencil value is not the maximum representable value, increase the stencil value by one.
    /// Otherwise, if the current stencil value is the maximum representable value, set the stencil value to zero.
    case incrementAndWrap

    /// If the current stencil value is not zero, decrease the stencil value by one.
    /// Otherwise, if the current stencil value is zero, set the stencil value to the maximum representable value.
    case decrementAndWrap
}

// MARK: - Others -

/// The geometric primitive type for drawing commands.
public enum IndexPrimitive: UInt8, Codable, Sendable {
    /// For every separate set of three vertices, rasterize a triangle. If the number of vertices is not a multiple of three, either one or two vertices is ignored.
    case triangle

    /// For every three adjacent vertices, rasterize a triangle.
    case triangleStrip

    /// Rasterize a line between each separate pair of vertices, resulting in a series of unconnected lines. If there are an odd number of vertices, the last vertex is ignored.
    case line

    /// Rasterize a line between each pair of adjacent vertices, resulting in a series of connected lines (also called a polyline).
    case lineStrip

    /// Rasterize a point at each vertex.
    case points
}

/// Types of actions performed for an attachment at the start of a rendering pass.
public enum AttachmentLoadAction: Codable, Sendable {
    /// The GPU writes a value to every pixel in the attachment at the start of the render pass.
    case clear

    /// The GPU preserves the existing contents of the attachment at the start of the render pass.
    case load

    /// The GPU has permission to discard the existing contents of the attachment at the start of the render pass, replacing them with arbitrary data.
    case dontCare
}

/// Types of actions performed for an attachment at the end of a rendering pass.
public enum AttachmentStoreAction: Codable, Sendable {
    /// The GPU stores the rendered contents to the texture.
    case store

    /// The GPU has permission to discard the rendered contents of the attachment at the end of the render pass, replacing them with arbitrary data.
    case dontCare
}

/// Options used to specify how a sample compare operation should be performed on a depth texture.
public enum CompareOperation: UInt, Codable, Sendable {
    /// A new value never passes the comparison test.
    case never

    /// A new value always passes the comparison test.
    case always

    /// A new value passes the comparison test if it is equal to the existing value.
    case equal

    /// A new value passes the comparison test if it is not equal to the existing value.
    case notEqual

    /// A new value passes the comparison test if it is less than the existing value.
    case less

    /// A new value passes the comparison test if it is less than or equal to the existing value.
    case lessOrEqual

    /// A new value passes the comparison test if it is greater than the existing value.
    case greater

    /// A new value passes the comparison test if it is greater than or equal to the existing value.
    case greaterOrEqual
}

/// The data formats that describe the organization and characteristics of individual pixels in a texture.
public enum PixelFormat: Codable, Sendable {
    /// You cannot create a texture with this value.
    case none

    /// Ordinary format with four 8-bit normalized unsigned integer components in BGRA order.
    case bgra8

    /// Ordinary format with four 8-bit normalized unsigned integer components in BGRA order with conversion between sRGB and linear space.
    case bgra8_srgb

    /// Ordinary format with four 8-bit normalized unsigned integer components in RGBA order.
    case rgba8

    /// Ordinary format with four 16-bit floating-point components in RGBA order.
    case rgba_16f

    /// Ordinary format with four 32-bit floating-point components in RGBA order.
    case rgba_32f

    /// A 40-bit combined depth and stencil pixel format with a 32-bit floating-point value for depth and an 8-bit unsigned integer for stencil.
    case depth_32f_stencil8

    /// A pixel format with one 32-bit floating-point component, used for a depth render target.
    case depth_32f

    /// A 32-bit combined depth and stencil pixel format with a 24-bit normalized unsigned integer for depth and an 8-bit unsigned integer for stencil.
    @available(macOS 11, *)
    case depth24_stencil8
}

extension PixelFormat {
    /// Return bits per component.
    public var bytesPerComponent: Int {
        switch self {
        case .none:
            return 0
        case .bgra8,
            .bgra8_srgb,
            .rgba8:
            return 4
        case .rgba_16f:
            return 8
        case .rgba_32f,
            .depth_32f_stencil8,
            .depth_32f:
            return 16
        case .depth24_stencil8:
            return 8
        }
    }

    /// Returns `true` if pixel format is depth format.
    public var isDepthFormat: Bool {
        #if MACOS
            self == .depth_32f_stencil8 || self == .depth_32f || self == .depth24_stencil8
        #else
            self == .depth_32f_stencil8 || self == .depth_32f
        #endif
    }

    /// Bytes per pixel for ordinary color textures (used for row pitch when uploading pixel data).
    public var uncompressedColorBytesPerPixel: Int? {
        switch self {
        case .bgra8,
            .bgra8_srgb,
            .rgba8:
            return 4
        case .rgba_16f:
            return 8
        case .rgba_32f:
            return 16
        case .none,
            .depth_32f_stencil8,
            .depth_32f,
            .depth24_stencil8:
            return nil
        }
    }
}
