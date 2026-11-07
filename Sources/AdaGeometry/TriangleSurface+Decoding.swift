import Foundation
import Math

extension TriangleSurface {
    private enum CodingKeys: String, CodingKey { case positions, normals, textureCoordinates, indices, faceSources, faceIDs }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        positions = try MeshTerrainDecoding.list(Vector3.self, key: .positions, in: container, decoder: decoder, maximum: 786_432)
        normals = try MeshTerrainDecoding.list(Vector3.self, key: .normals, in: container, decoder: decoder, maximum: 786_432)
        textureCoordinates = try MeshTerrainDecoding.list(Vector2.self, key: .textureCoordinates, in: container, decoder: decoder, maximum: 786_432)
        indices = try MeshTerrainDecoding.list(UInt32.self, key: .indices, in: container, decoder: decoder, maximum: 786_432)
        faceSources = try MeshTerrainDecoding.list(UInt32.self, key: .faceSources, in: container, decoder: decoder, maximum: 262_144)
        faceIDs = try MeshTerrainDecoding.list(UInt32.self, key: .faceIDs, in: container, decoder: decoder, maximum: 262_144)
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(positions, forKey: .positions)
        try container.encode(normals, forKey: .normals)
        try container.encode(textureCoordinates, forKey: .textureCoordinates)
        try container.encode(indices, forKey: .indices)
        try container.encode(faceSources, forKey: .faceSources)
        try container.encode(faceIDs, forKey: .faceIDs)
    }
}
