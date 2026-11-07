import Foundation
import Math

public enum TerrainMaterialProjection: String, Codable, Sendable {
    case planar, triplanar
}

/// A stable terrain layer; texture paths are relative to the terrain manifest.
public struct TerrainLayerReference: Codable, Equatable, Sendable {
    public let id: UInt16
    public let name: String
    public let albedoPath: String?
    public let normalPath: String?
    /// Linear ambient-occlusion/roughness/metallic channels in R/G/B respectively.
    public let ormPath: String?
    public let blendHeightPath: String?
    /// Terrain-local units per texture repetition.
    public let scale: Float
    public let tint: Vector4
    public let roughness: Float
    public let metallic: Float
    public let projection: TerrainMaterialProjection
    public let variation: TerrainTextureVariation

    public init(
        id: UInt16,
        name: String,
        albedoPath: String? = nil,
        normalPath: String? = nil,
        ormPath: String? = nil,
        blendHeightPath: String? = nil,
        scale: Float = 1,
        tint: Vector4 = [1, 1, 1, 1],
        roughness: Float = 1,
        metallic: Float = 0,
        projection: TerrainMaterialProjection = .planar,
        variation: TerrainTextureVariation = .init()
    ) {
        self.id = id; self.name = name; self.albedoPath = albedoPath; self.normalPath = normalPath; self.ormPath = ormPath
        self.variation = variation
        self.blendHeightPath = blendHeightPath; self.scale = scale; self.tint = tint; self.roughness = roughness; self.metallic = metallic; self.projection = projection
    }

    private enum CodingKeys: CodingKey { case id, name, albedoPath, normalPath, ormPath, blendHeightPath, scale, tint, roughness, metallic, projection, variation }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UInt16.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            albedoPath: try container.decodeIfPresent(String.self, forKey: .albedoPath),
            normalPath: try container.decodeIfPresent(String.self, forKey: .normalPath),
            ormPath: try container.decodeIfPresent(String.self, forKey: .ormPath),
            blendHeightPath: try container.decodeIfPresent(String.self, forKey: .blendHeightPath),
            scale: try container.decodeIfPresent(Float.self, forKey: .scale) ?? 1,
            tint: try container.decodeIfPresent(Vector4.self, forKey: .tint) ?? [1, 1, 1, 1],
            roughness: try container.decodeIfPresent(Float.self, forKey: .roughness) ?? 1,
            metallic: try container.decodeIfPresent(Float.self, forKey: .metallic) ?? 0,
            projection: try container.decodeIfPresent(TerrainMaterialProjection.self, forKey: .projection) ?? .planar,
            variation: try container.decodeIfPresent(TerrainTextureVariation.self, forKey: .variation) ?? .init()
        )
    }

    func validate() throws {
        try variation.validate()
        guard !name.isEmpty, name.utf8.count <= 128, !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
            scale.isFinite, scale > 0, roughness.isFinite, (0...1).contains(roughness), metallic.isFinite, (0...1).contains(metallic),
            [tint.x, tint.y, tint.z, tint.w].allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else {
            throw TerrainManifestError.malformed("invalid terrain material layer")
        }
        for path in [albedoPath, normalPath, ormPath, blendHeightPath].compactMap({ $0 }) {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, path.utf8.count <= 512,
                !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || "\\:%?#\"<>|*".unicodeScalars.contains($0) }),
                components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 128 && $0.last != "." && $0.last != " " })
            else {
                throw TerrainManifestError.malformed("invalid terrain material texture reference")
            }
        }
    }
}
