import Foundation
import Math

/// Immutable base-level CPU alpha retained at upload time for picking, without GPU readback.
/// Constant-alpha images use one value; other images retain one byte per texel.
public struct TextureAlphaMask: Sendable {
    public let width: Int
    public let height: Int
    private let constant: UInt8?
    private let samples: [UInt8]

    public init?(image: Image) {
        let count = image.width.multipliedReportingOverflow(by: image.height)
        let channels: Int
        switch image.format {
        case .rgba8, .bgra8, .bgra8_sRGB: channels = 4
        case .rgb8: channels = 3
        case .gray: channels = 1
        }
        let bytes = count.partialValue.multipliedReportingOverflow(by: channels)
        guard image.width > 0, image.height > 0, !count.overflow, !bytes.overflow, image.data.count == bytes.partialValue else {
            return nil
        }
        self.width = image.width
        self.height = image.height
        if channels != 4 {
            self.constant = 255
            self.samples = []
            return
        }
        let texels = count.partialValue
        // Scan raw bytes: per-element `Data` subscripts dominate import time for 4K material textures.
        let (first, isConstant) = unsafe image.data.withUnsafeBytes { raw -> (UInt8, Bool) in
            let bytes = unsafe raw.bindMemory(to: UInt8.self)
            let first = unsafe bytes[3]
            for index in 1 ..< texels where unsafe bytes[index * 4 + 3] != first {
                return (first, false)
            }
            return (first, true)
        }
        self.constant = isConstant ? first : nil
        if isConstant {
            self.samples = []
        } else {
            self.samples = unsafe image.data.withUnsafeBytes { raw in
                let bytes = unsafe raw.bindMemory(to: UInt8.self)
                return unsafe [UInt8](unsafeUninitializedCapacity: texels) { output, initialized in
                    for index in 0 ..< texels { unsafe output[index] = bytes[index * 4 + 3] }
                    initialized = texels
                }
            }
        }
    }

    /// Samples a nearest base-level texel using GPU UVs (top-left image origin).
    /// UVs outside 0...1, or non-finite UVs, return nil.
    public func alpha(at uv: Vector2) -> Float? {
        guard uv.x.isFinite, uv.y.isFinite, uv.x >= 0, uv.y >= 0, uv.x <= 1, uv.y <= 1 else {
            return nil
        }
        if let constant {
            return Float(constant) / 255
        }
        func pixel(_ coordinate: Float, length: Int) -> Int {
            let scaled = Double(coordinate) * Double(length)
            return scaled >= Double(length - 1) ? length - 1 : Int(scaled)
        }
        let x = pixel(uv.x, length: width)
        let y = pixel(uv.y, length: height)
        return Float(samples[y * width + x]) / 255
    }
}
