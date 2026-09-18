//
//  Sampler.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/22/23.
//

/// Filtering options for determining which pixel value is returned within a mipmap level.
public enum SamplerMinMagFilter: String, Codable, Sendable {
    /// Select the single pixel nearest to the sample point.
    case nearest

    /// Select two pixels in each dimension and interpolate linearly between them.
    case linear
}

/// Filtering options for determining what pixel value is returned with multiple mipmap levels.
public enum SamplerMipFilter: String, Codable, Sendable {
    /// The nearest mipmap level is selected.
    case nearest

    /// If the filter falls between mipmap levels, both levels are sampled and the results are determined by linear interpolation between levels.
    case linear

    /// The texture is sampled from mipmap level 0, and other mipmap levels are ignored.
    case notMipmapped
}

/// An object that you use to configure a texture sampler.
public struct SamplerDescriptor: Codable, Sendable {
    /// The filtering option for combining pixels within one mipmap level when the sample footprint is larger than a pixel (minification).
    public var minFilter: SamplerMinMagFilter

    /// The filtering operation for combining pixels within one mipmap level when the sample footprint is smaller than a pixel (magnification).
    public var magFilter: SamplerMinMagFilter

    /// The filtering option for combining pixels between two mipmap levels.
    public var mipFilter: SamplerMipFilter

    /// The minimum level of detail (LOD) to use when sampling from a texture.
    public var lodMinClamp: Float

    /// The maximum level of detail (LOD) to use when sampling from a texture.
    public var lodMaxClamp: Float

    /// Initialize a new sampler descriptor.
    ///
    /// - Parameter minFilter: The filtering option for combining pixels within one mipmap level when the sample footprint is larger than a pixel (minification).
    /// - Parameter magFilter: The filtering operation for combining pixels within one mipmap level when the sample footprint is smaller than a pixel (magnification).
    /// - Parameter mipFilter: The filtering option for combining pixels between two mipmap levels.
    /// - Parameter lodMinClamp: The minimum level of detail (LOD) to use when sampling from a texture.
    /// - Parameter lodMaxClamp: The maximum level of detail (LOD) to use when sampling from a texture.
    public init(
        minFilter: SamplerMinMagFilter = .nearest,
        magFilter: SamplerMinMagFilter = .nearest,
        mipFilter: SamplerMipFilter = .nearest,
        lodMinClamp: Float = 0,
        lodMaxClamp: Float = .greatestFiniteMagnitude
    ) {
        self.minFilter = minFilter
        self.magFilter = magFilter
        self.mipFilter = mipFilter
        self.lodMinClamp = lodMinClamp
        self.lodMaxClamp = lodMaxClamp
    }
}

/// Sampler representation in GPU. You can create your own sampler instance for manage how to draw texture.
public protocol Sampler: AnyObject, Sendable {
    /// Contains information about sampler descriptor.
    var descriptor: SamplerDescriptor { get }
}
