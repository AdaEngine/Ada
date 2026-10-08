import AdaAssets
import AdaRender
import Foundation
import Math

/// Offline-integrated linear HDR IBL. Specular roughness levels form a vertical equirectangular atlas.
public struct ImageBasedLighting3D: Asset, Sendable {
    public struct Map: Codable, Sendable {
        public let file: String
        public let width: Int
        public let height: Int
    }

    public struct Manifest: Codable, Sendable {
        public let version: Int
        public let radiance: Map?
        public let irradiance: Map
        public let specular: Map
        public let brdf: Map
        public let specularLevels: Int
    }

    public let radiance: Texture2D?
    public let irradiance: Texture2D
    public let specular: Texture2D
    public let brdf: Texture2D
    public let specularLevels: Int
    public var assetMetaInfo: AssetMetaInfo?

    public init(irradiance: Texture2D, specular: Texture2D, brdf: Texture2D, specularLevels: Int, radiance: Texture2D? = nil) {
        self.radiance = radiance
        self.irradiance = irradiance
        self.specular = specular
        self.brdf = brdf
        self.specularLevels = specularLevels
    }

    public init(from decoder: any AssetDecoder) async throws {
        let manifest = try decoder.decode(Manifest.self)
        guard manifest.version == 1, (2 ... 16).contains(manifest.specularLevels), manifest.specular.height.isMultiple(of: manifest.specularLevels) else {
            throw AssetError.message("Invalid IBL manifest")
        }
        let directory = decoder.assetMeta.filePath.deletingLastPathComponent()
        func load(_ map: Map, wrapsLongitude: Bool) throws -> Texture2D {
            guard (1 ... 4096).contains(map.width), (1 ... 4096).contains(map.height),
                  map.file == URL(fileURLWithPath: map.file).lastPathComponent
            else { throw AssetError.message("Invalid IBL map") }
            let data = try Data(contentsOf: directory.appendingPathComponent(map.file))
            guard data.count == map.width * map.height * 8 else { throw AssetError.message("Invalid IBL map byte count") }
            for offset in stride(from: 0, to: data.count, by: 2) {
                let bits = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
                // Validate IEEE 754 binary16 directly; Float16 is unavailable on Intel macOS.
                // An all-ones exponent is nonfinite. Accept either sign of zero.
                guard bits & 0x7C00 != 0x7C00, bits & 0x8000 == 0 || bits & 0x7FFF == 0 else {
                    throw AssetError.message("IBL contains invalid radiance")
                }
            }
            let texture = Texture2D(descriptor: TextureDescriptor(
                width: map.width,
                height: map.height,
                pixelFormat: .rgba_16f,
                textureUsage: [.read],
                textureType: .texture2D,
                debugLabel: "IBL \(map.file)",
                samplerDescription: SamplerDescriptor(
                    minFilter: .linear,
                    magFilter: .linear,
                    mipFilter: .notMipmapped,
                    addressModeU: wrapsLongitude ? .repeat : .clampToEdge
                )
            ))
            unsafe data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else {
                    return
                }
                unsafe texture.replaceRegion(RectInt(x: 0, y: 0, width: map.width, height: map.height), withBytes: base, bytesPerRow: map.width * 8)
            }
            return texture
        }
        radiance = try manifest.radiance.map { try load($0, wrapsLongitude: true) }
        irradiance = try load(manifest.irradiance, wrapsLongitude: true)
        specular = try load(manifest.specular, wrapsLongitude: true)
        brdf = try load(manifest.brdf, wrapsLongitude: false)
        specularLevels = manifest.specularLevels
    }

    public func encodeContents(with _: any AssetEncoder) async throws {
        throw AssetError.message("Bake IBL maps with Tools/3DAssets/bake_ibl.py")
    }

    public static func extensions() -> [String] { ["ibl"] }
}
