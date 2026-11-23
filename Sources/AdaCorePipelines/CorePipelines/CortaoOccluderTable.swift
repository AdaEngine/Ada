import AdaRender
import Foundation
import Math

/// Precomputed ray hit masks for CORTAO circular occluders.
///
/// For an occluder seen from a surface point, the main pass needs to know which of the 16 hemisphere rays it blocks.
/// That depends only on the occluder's direction in the point's tangent frame and its angular radius, so the answer
/// is tabulated: a direction (octahedral-free spheremap, 24 x 24) and a radius (16 slices) address a 16-bit mask.
/// This is the "occluder look-up table" of the reference implementation
/// (https://github.com/theagentd/CORTAO, Copyright (c) 2026 Daniel Isheden, MIT License, see Assets/Shaders/CORTAO-LICENSE.txt), generated at run time
/// instead of shipped as data.
///
/// The table is stored as an R32Float texture, `directionResolution * radiusResolution` texels wide so that radius
/// slices sit side by side: texel `(x + directionResolution * slice, y)`. Masks are small integers, exact in Float.
/// The addressing and ray layout must match `cortao_3d.wesl`.
enum CortaoOccluderTable {
    static let directionResolution = 24
    static let radiusResolution = 16
    static let rayCount = 16
    static let width = directionResolution * radiusResolution
    static let height = directionResolution

    /// Hemisphere ray `index` in tangent space, distributed on a golden-angle spiral (cosine weighted).
    static func rayDirection(_ index: Int) -> SIMD3<Float> {
        let angle: Float = Float(index) * 2.3999632
        let fraction: Float = (Float(index) + 0.5) / Float(rayCount)
        let radius: Float = fraction.squareRoot()
        let x: Float = Foundation.cos(angle) * radius
        let y: Float = Foundation.sin(angle) * radius
        let z: Float = (1 - fraction).squareRoot()
        return SIMD3<Float>(x, y, z)
    }

    /// Direction addressed by a table cell, or nil when the spheremap texel lies outside the unit sphere.
    static func direction(x: Int, y: Int) -> SIMD3<Float>? {
        let ex = (Float(x) + 0.5) / Float(directionResolution) - 0.5
        let ey = (Float(y) + 0.5) / Float(directionResolution) - 0.5
        let squared = ex * ex + ey * ey
        guard squared <= 0.25 else {
            return nil
        }
        let scale: Float = 4 * (1 - 4 * squared).squareRoot()
        return SIMD3<Float>(ex * scale, ey * scale, 1 - 8 * squared)
    }

    /// Angular occluder radius (radians-like chord measure used by the shader) at the centre of a radius slice.
    static func occluderRadius(slice: Int) -> Float {
        (Float(slice) + 0.5) / Float(radiusResolution) / Float(0.5).squareRoot()
    }

    /// Bit `j` is set when ray `j` falls inside the occluder cone.
    static func mask(x: Int, y: Int, slice: Int) -> UInt32 {
        guard let direction = direction(x: x, y: y), direction.z > -0.99 else {
            return 0
        }
        let radius = occluderRadius(slice: slice)
        let cosine = max(0, 1 - radius * radius * 0.5)
        var bits: UInt32 = 0
        for ray in 0..<rayCount {
            let r = rayDirection(ray)
            let dot: Float = r.x * direction.x + r.y * direction.y + r.z * direction.z
            if dot > cosine {
                bits |= 1 << UInt32(ray)
            }
        }
        return bits
    }

    /// Row-major texels of the R32Float table.
    static func texels() -> [Float] {
        var texels = [Float](repeating: 0, count: width * height)
        for slice in 0..<radiusResolution {
            for y in 0..<directionResolution {
                for x in 0..<directionResolution {
                    texels[y * width + slice * directionResolution + x] = Float(mask(x: x, y: y, slice: slice))
                }
            }
        }
        return texels
    }

    static func makeTexture() -> Texture2D {
        let texture = Texture2D(descriptor: TextureDescriptor(
            width: width,
            height: height,
            pixelFormat: .r32f,
            textureUsage: [.read],
            textureType: .texture2D,
            debugLabel: "CORTAO occluder table",
            samplerDescription: SamplerDescriptor(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped)
        ))
        let texels = texels()
        unsafe texels.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                unsafe texture.replaceRegion(RectInt(x: 0, y: 0, width: width, height: height), withBytes: base, bytesPerRow: width * 4)
            }
        }
        return texture
    }
}
