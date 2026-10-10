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

/// Wrapping outside the normalized texture coordinate range.
public enum SamplerAddressMode: String, Codable, Sendable {
    case clampToEdge
    case `repeat`
    case mirroredRepeat
}

/// An object that you use to configure a texture sampler.
public struct SamplerDescriptor: Codable, Equatable, Sendable {
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
    public var addressModeU: SamplerAddressMode
    public var addressModeV: SamplerAddressMode
    public var addressModeW: SamplerAddressMode

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
        lodMaxClamp: Float = .greatestFiniteMagnitude,
        addressModeU: SamplerAddressMode = .clampToEdge,
        addressModeV: SamplerAddressMode = .clampToEdge,
        addressModeW: SamplerAddressMode = .clampToEdge
    ) {
        self.minFilter = minFilter
        self.magFilter = magFilter
        self.mipFilter = mipFilter
        self.lodMinClamp = lodMinClamp
        self.lodMaxClamp = lodMaxClamp
        self.addressModeU = addressModeU
        self.addressModeV = addressModeV
        self.addressModeW = addressModeW
    }

    private enum CodingKeys: String, CodingKey {
        case minFilter, magFilter, mipFilter, lodMinClamp, lodMaxClamp, addressModeU, addressModeV, addressModeW
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            minFilter: values.decodeIfPresent(SamplerMinMagFilter.self, forKey: .minFilter) ?? .nearest,
            magFilter: values.decodeIfPresent(SamplerMinMagFilter.self, forKey: .magFilter) ?? .nearest,
            mipFilter: values.decodeIfPresent(SamplerMipFilter.self, forKey: .mipFilter) ?? .nearest,
            lodMinClamp: values.decodeIfPresent(Float.self, forKey: .lodMinClamp) ?? 0,
            lodMaxClamp: values.decodeIfPresent(Float.self, forKey: .lodMaxClamp) ?? .greatestFiniteMagnitude,
            addressModeU: values.decodeIfPresent(SamplerAddressMode.self, forKey: .addressModeU) ?? .clampToEdge,
            addressModeV: values.decodeIfPresent(SamplerAddressMode.self, forKey: .addressModeV) ?? .clampToEdge,
            addressModeW: values.decodeIfPresent(SamplerAddressMode.self, forKey: .addressModeW) ?? .clampToEdge
        )
    }
}

/// Sampler representation in GPU. You can create your own sampler instance for manage how to draw texture.
public protocol Sampler: AnyObject, Sendable {
    /// Contains information about sampler descriptor.
    var descriptor: SamplerDescriptor { get }
}
