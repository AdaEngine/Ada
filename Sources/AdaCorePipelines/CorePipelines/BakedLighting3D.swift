import AdaAssets
import AdaRender
import Foundation
import Math

/// Portable linear RGBA16F data. SH maps permit signed RGB; lightmaps never do.
struct BakedHDRMap3D: Codable, Sendable {
    var file: String
    var width: Int
    var height: Int

    func load(in directory: URL, signed: Bool = false) throws -> Texture2D {
        guard (1...4096).contains(width), (1...4096).contains(height), !file.isEmpty,
            !file.contains("/"), !file.contains("\\"), file != ".", file != ".."
        else { throw AssetError.message("Invalid baked HDR map") }
        let data = try Data(contentsOf: directory.appendingPathComponent(file), options: .mappedIfSafe)
        guard data.count == width * height * 8 else { throw AssetError.message("Invalid baked HDR byte count") }
        for offset in stride(from: 0, to: data.count, by: 2) {
            let bits = UInt16(data[offset]) | UInt16(data[offset+1]) << 8
            guard bits & 0x7C00 != 0x7C00, signed || bits & 0x8000 == 0 || bits & 0x7FFF == 0 else {
                throw AssetError.message("Nonfinite or negative baked lighting data")
            }
        }
        let texture = Texture2D(descriptor: TextureDescriptor(width: width, height: height,
            pixelFormat: .rgba_16f, textureUsage: [.read], textureType: .texture2D, debugLabel: "Baked \(file)",
            samplerDescription: .init(minFilter: .linear, magFilter: .linear, mipFilter: .notMipmapped,
                addressModeU: .clampToEdge, addressModeV: .clampToEdge)))
        unsafe data.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                unsafe texture.replaceRegion(RectInt(x: 0, y: 0, width: width, height: height), withBytes: base, bytesPerRow: width*8)
            }
        }
        return texture
    }
}

/// Non-directional incident diffuse lighting / pi, indexed by the derived model's global material index.
/// Contains environment visibility and static diffuse bounces; excludes runtime analytic direct light.
public struct LightmapSet3D: Asset, Sendable {
    public var assetMetaInfo: AssetMetaInfo?
    public let materials: [Int: Texture2D]
    public let modelFile: String

    public init(materials: [Int: Texture2D], modelFile: String = "") {
        self.materials = materials; self.modelFile = modelFile
    }
    public init(from decoder: any AssetDecoder) async throws {
        struct Manifest: Decodable {
            var version: Int; var encoding: String; var modelFile: String; var materials: [String: BakedHDRMap3D]
        }
        let manifest = try decoder.decode(Manifest.self)
        guard manifest.version == 1, manifest.encoding == "diffuse-irradiance-over-pi", manifest.materials.count <= 4096 else {
            throw AssetError.message("Invalid lightmap manifest or lighting convention")
        }
        let directory = decoder.assetMeta.filePath.deletingLastPathComponent()
        guard manifest.materials.values.allSatisfy({ (1...4096).contains($0.width) && (1...4096).contains($0.height) }),
            manifest.materials.values.reduce(0, { $0 + $1.width * $1.height * 8 }) <= 256 * 1024 * 1024
        else { throw AssetError.message("Lightmap set exceeds the 256 MiB budget") }
        var textures: [Int: Texture2D] = [:]
        for (key, map) in manifest.materials {
            guard let index = Int(key), index >= 0, String(index) == key else { throw AssetError.message("Invalid lightmap material index") }
            textures[index] = try map.load(in: directory)
        }
        materials = textures; modelFile = manifest.modelFile
    }
    public func encodeContents(with _: any AssetEncoder) async throws { throw AssetError.message("Use Tools/3DAssets/bake_gi.py") }
    public static func extensions() -> [String] { ["lightmaps"] }
}

/// L2 RGB SH irradiance / pi and octahedral distance moments for each regular-grid probe.
public struct IrradianceProbeGrid3D: Asset, Sendable {
    public var assetMetaInfo: AssetMetaInfo?
    public let origin: Vector3
    public let spacing: Vector3
    public let counts: [Int]
    public let visibilityResolution: Int
    public let coefficients: Texture2D
    public let visibility: Texture2D

    public init(origin: Vector3, spacing: Vector3, counts: [Int], visibilityResolution: Int,
        coefficients: Texture2D, visibility: Texture2D) throws {
        guard Self.valid(origin: origin, spacing: spacing, counts: counts, resolution: visibilityResolution),
            coefficients.size == SizeInt(width: counts[0]*9, height: counts[1]*counts[2]),
            visibility.size == SizeInt(width: counts[0]*visibilityResolution, height: counts[1]*counts[2]*visibilityResolution)
        else { throw AssetError.message("Invalid irradiance grid layout") }
        self.origin = origin; self.spacing = spacing; self.counts = counts
        self.visibilityResolution = visibilityResolution; self.coefficients = coefficients; self.visibility = visibility
    }
    public static func valid(origin: Vector3, spacing: Vector3, counts: [Int], resolution: Int) -> Bool {
        guard origin.x.isFinite, origin.y.isFinite, origin.z.isFinite,
            spacing.x.isFinite, spacing.y.isFinite, spacing.z.isFinite,
            min(spacing.x, min(spacing.y, spacing.z)) >= 0.01,
            counts.count == 3, counts.allSatisfy({ (2...64).contains($0) }), [8,16,32].contains(resolution)
        else { return false }
        return counts[0]*counts[1]*counts[2] <= 4096 && counts[0]*resolution <= 4096 && counts[1]*counts[2]*resolution <= 4096
    }
    public init(from decoder: any AssetDecoder) async throws {
        struct Manifest: Decodable {
            var version: Int; var encoding: String; var origin: Vector3; var spacing: Vector3; var counts: [Int]
            var visibilityResolution: Int; var coefficients: BakedHDRMap3D; var visibility: BakedHDRMap3D
        }
        let m = try decoder.decode(Manifest.self)
        guard m.version == 1, m.encoding == "sh9-diffuse-irradiance-over-pi",
            Self.valid(origin: m.origin, spacing: m.spacing, counts: m.counts, resolution: m.visibilityResolution),
            m.coefficients.width == m.counts[0]*9, m.coefficients.height == m.counts[1]*m.counts[2],
            m.visibility.width == m.counts[0]*m.visibilityResolution, m.visibility.height == m.counts[1]*m.counts[2]*m.visibilityResolution
        else { throw AssetError.message("Invalid irradiance grid manifest") }
        let directory = decoder.assetMeta.filePath.deletingLastPathComponent()
        try self.init(origin: m.origin, spacing: m.spacing, counts: m.counts, visibilityResolution: m.visibilityResolution,
            coefficients: m.coefficients.load(in: directory, signed: true), visibility: m.visibility.load(in: directory))
    }
    public func encodeContents(with _: any AssetEncoder) async throws { throw AssetError.message("Use Tools/3DAssets/bake_gi.py") }
    public static func extensions() -> [String] { ["probegrid"] }
}

public struct IrradianceProbeSettings3D: Codable, Sendable {
    public var asset: AssetHandle<IrradianceProbeGrid3D>
    public var intensity: Float
    public var normalBias: Float
    public var visibilityBias: Float
    /// Optional GPU relighting of static probe-to-surface paths by explicitly opted-in local lights.
    public var dynamic: DynamicIrradianceSettings3D?
    public init(asset: AssetHandle<IrradianceProbeGrid3D>, intensity: Float = 1, normalBias: Float = 0.08, visibilityBias: Float = 0.04,
        dynamic: DynamicIrradianceSettings3D? = nil) {
        self.asset = asset; self.intensity = intensity; self.normalBias = normalBias; self.visibilityBias = visibilityBias
        self.dynamic = dynamic
    }
}

struct IrradianceGrid3DUniform: Sendable {
    var originIntensity: Vector4
    var spacingNormalBias: Vector4
    var countsVisibilityBias: Vector4
    var quality: Vector4
}
