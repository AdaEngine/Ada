import AdaAssets
import AdaRender
import Foundation
import Math

/// Node-centered world-space signed distances in metres, stored as tiled R32F Z slices.
/// Negative values are inside static occluders. The field does not follow moving geometry.
public struct DistanceField3D: Asset, Sendable {
    public var assetMetaInfo: AssetMetaInfo?
    public let minimum: Vector3
    public let voxelSize: Float
    public let counts: [Int]
    public let texture: Texture2D
    public let atlasColumns: Int

    /// The caller supplies a linear R32F texture; imported `.sdf3d` assets validate the raw samples.
    public init(minimum: Vector3, voxelSize: Float, counts: [Int], texture: Texture2D, atlasColumns: Int = 1) throws {
        guard let size = Self.atlasSize(minimum: minimum, voxelSize: voxelSize, counts: counts, columns: atlasColumns),
            texture.size == size else { throw AssetError.message("Invalid distance-field layout") }
        self.minimum = minimum; self.voxelSize = voxelSize; self.counts = counts
        self.texture = texture; self.atlasColumns = atlasColumns
    }

    static func atlasSize(minimum: Vector3, voxelSize: Float, counts: [Int], columns: Int) -> SizeInt? {
        guard LocalLighting3DMath.isFinite(minimum), voxelSize.isFinite, (0.001...10000).contains(voxelSize),
            counts.count == 3, counts.allSatisfy({ (2...4096).contains($0) }),
            columns >= 1, columns <= counts[2] else { return nil }
        let width = counts[0] * columns
        let height = counts[1] * ((counts[2] + columns - 1) / columns)
        let extent = Vector3(Float(counts[0]-1), Float(counts[1]-1), Float(counts[2]-1)) * voxelSize
        guard width <= 4096, height <= 4096, width * height * 4 <= 32 * 1024 * 1024,
            LocalLighting3DMath.isFinite(minimum + extent) else { return nil }
        return SizeInt(width: width, height: height)
    }

    public init(from decoder: any AssetDecoder) async throws {
        struct Manifest: Decodable {
            var version: Int; var encoding: String; var minimum: Vector3; var voxelSize: Float
            var counts: [Int]; var data: String; var atlasColumns: Int?
        }
        let m = try decoder.decode(Manifest.self)
        guard m.version == 1, m.encoding == "signed-distance-r32f-slices-v1",
            let size = Self.atlasSize(minimum: m.minimum, voxelSize: m.voxelSize, counts: m.counts, columns: m.atlasColumns ?? 1),
            !m.data.isEmpty, m.data != ".", m.data != "..",
            !m.data.contains("/"), !m.data.contains("\\"), !m.data.contains(":"), !m.data.contains("\0")
        else { throw AssetError.message("Invalid distance-field manifest") }
        let directory = decoder.assetMeta.filePath.deletingLastPathComponent().resolvingSymlinksInPath()
        let file = directory.appendingPathComponent(m.data).resolvingSymlinksInPath()
        guard file.deletingLastPathComponent() == directory,
            try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == size.width * size.height * 4
        else { throw AssetError.message("Invalid distance-field file path or size") }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count == size.width * size.height * 4 else { throw AssetError.message("Invalid distance-field byte count") }
        let finite = unsafe data.withUnsafeBytes { bytes in
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let bits = unsafe UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                if !Float(bitPattern: bits).isFinite { return false }
            }
            return true
        }
        guard finite else { throw AssetError.message("Nonfinite distance-field samples") }
        let texture = Texture2D(descriptor: .init(width: size.width, height: size.height,
            pixelFormat: .r32f, textureUsage: [.read], textureType: .texture2D, debugLabel: "World distance field",
            samplerDescription: .init(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped,
                addressModeU: .clampToEdge, addressModeV: .clampToEdge)))
        unsafe data.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                unsafe texture.replaceRegion(RectInt(x: 0, y: 0, width: size.width, height: size.height), withBytes: base, bytesPerRow: size.width * 4)
            }
        }
        try self.init(minimum: m.minimum, voxelSize: m.voxelSize, counts: m.counts, texture: texture, atlasColumns: m.atlasColumns ?? 1)
    }

    public func encodeContents(with _: any AssetEncoder) async throws { throw AssetError.message("Use the offline distance-field baker") }
    public static func extensions() -> [String] { ["sdf3d"] }
}

/// Static world-space directional shadows. Missing/unloaded fields safely retain ordinary shadow maps.
public struct DistanceFieldSettings3D: Codable, Sendable {
    public var asset: AssetHandle<DistanceField3D>
    public var maxDistance: Float
    public var maxSteps: Int
    public var surfaceBias: Float
    /// Cone tangent controlling distance-field penumbra width; zero gives hard visibility.
    public var softness: Float
    /// False renders normal lighting; true displays SDF sun visibility as a red/green overlay.
    public var debug: Bool

    public init(asset: AssetHandle<DistanceField3D>, maxDistance: Float = 12, maxSteps: Int = 48,
                surfaceBias: Float = 0.12, softness: Float = 0.02, debug: Bool = false) {
        self.asset = asset; self.maxDistance = maxDistance; self.maxSteps = maxSteps
        self.surfaceBias = surfaceBias; self.softness = softness; self.debug = debug
    }

    private enum CodingKeys: CodingKey { case asset, maxDistance, maxSteps, surfaceBias, softness, debug }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(asset: try c.decode(AssetHandle<DistanceField3D>.self, forKey: .asset),
            maxDistance: try c.decodeIfPresent(Float.self, forKey: .maxDistance) ?? 12,
            maxSteps: try c.decodeIfPresent(Int.self, forKey: .maxSteps) ?? 48,
            surfaceBias: try c.decodeIfPresent(Float.self, forKey: .surfaceBias) ?? 0.12,
            softness: try c.decodeIfPresent(Float.self, forKey: .softness) ?? 0.02,
            debug: try c.decodeIfPresent(Bool.self, forKey: .debug) ?? false)
    }
}

struct DistanceField3DUniform: Sendable {
    var minimumVoxel: Vector4
    var countsDistance: Vector4
    var trace: Vector4

    init(settings: DistanceFieldSettings3D?) {
        guard let settings, let field = settings.asset.asset else {
            minimumVoxel = [0, 0, 0, 1]; countsDistance = [2, 2, 2, 0]; trace = .zero
            return
        }
        minimumVoxel = Vector4(field.minimum, field.voxelSize)
        countsDistance = [Float(field.counts[0]), Float(field.counts[1]), Float(field.counts[2]),
            finiteRenderValue(settings.maxDistance, fallback: 12, range: 0.1...100)]
        trace = [Float(min(max(settings.maxSteps, 1), 128)),
            finiteRenderValue(settings.surfaceBias, fallback: 0.12, range: 0...2),
            finiteRenderValue(settings.softness, fallback: 0.02, range: 0...1), settings.debug ? 2 : 1]
    }
}
