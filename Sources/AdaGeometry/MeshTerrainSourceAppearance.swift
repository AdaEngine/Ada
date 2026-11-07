import Foundation
import Math

/// Original opaque material groups in source-face order. Triangle operations
/// preserve these face IDs independently of the new triangle or vertex order.
public struct MeshTerrainSourceAppearance: Codable, Equatable, Sendable {
    public struct ModelMaterial: Codable, Equatable, Sendable {
        public let path: String
        public let index: Int

        public init(path: String, index: Int) { self.path = path; self.index = index }

        public static func supports(_ path: String) -> Bool {
            guard path.hasPrefix("@res://"), path.utf8.count <= 1024,
                !path.contains("%"), !path.dropFirst(7).contains(":"),
                !path.contains("\\"), !path.contains("?"), !path.contains("#"),
                path.lowercased().hasSuffix(".glb") || path.lowercased().hasSuffix(".gltf") else { return false }
            return path.dropFirst(7).split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
        }

        func validate() throws {
            guard Self.supports(path), (0..<65_536).contains(index) else { throw TriangleGeometryError.invalidInput }
        }
    }

    public struct Material: Codable, Equatable, Sendable {
        public let baseColor: Vector4
        public let roughness: Float
        public let metallic: Float
        public let emission: Vector3
        public let emissionStrength: Float
        public let doubleSided: Bool
        public let modelMaterial: ModelMaterial?

        public init(baseColor: Vector4, roughness: Float, metallic: Float, emission: Vector3, emissionStrength: Float,
                    doubleSided: Bool, modelMaterial: ModelMaterial? = nil) {
            self.baseColor = baseColor; self.roughness = roughness; self.metallic = metallic
            self.emission = emission; self.emissionStrength = emissionStrength; self.doubleSided = doubleSided
            self.modelMaterial = modelMaterial
        }

        func validate() throws {
            try modelMaterial?.validate()
            guard (0...1).contains(roughness), (0...1).contains(metallic), emissionStrength.isFinite, emissionStrength >= 0,
                (0..<4).allSatisfy({ baseColor[$0].isFinite && baseColor[$0] >= 0 }),
                (0..<3).allSatisfy({ emission[$0].isFinite && emission[$0] >= 0 }) else { throw TriangleGeometryError.invalidInput }
        }
    }

    public struct Part: Codable, Equatable, Sendable {
        public let firstFace: UInt32
        public let faceCount: UInt32
        public let material: Material

        public init(firstFace: UInt32, faceCount: UInt32, material: Material) {
            self.firstFace = firstFace; self.faceCount = faceCount; self.material = material
        }
    }

    public let parts: [Part]
    public let secondaryUV: [Vector2]?
    public let vertexColors: [Vector4]?

    public init(parts: [Part], secondaryUV: [Vector2]? = nil, vertexColors: [Vector4]? = nil) {
        self.parts = parts; self.secondaryUV = secondaryUV; self.vertexColors = vertexColors
    }

    private enum CodingKeys: CodingKey { case parts, secondaryUV, vertexColors }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parts = try MeshTerrainDecoding.list(Part.self, key: .parts, in: container, decoder: decoder, maximum: 512)
        secondaryUV = try container.contains(.secondaryUV)
            ? MeshTerrainDecoding.list(Vector2.self, key: .secondaryUV, in: container, decoder: decoder, maximum: 786_432) : nil
        vertexColors = try container.contains(.vertexColors)
            ? MeshTerrainDecoding.list(Vector4.self, key: .vertexColors, in: container, decoder: decoder, maximum: 786_432) : nil
    }

    public func validate(faceCount: Int, vertexCount: Int) throws {
        if let secondaryUV {
            guard secondaryUV.count == vertexCount, secondaryUV.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw TriangleGeometryError.invalidInput }
        }
        if let vertexColors {
            guard vertexColors.count == vertexCount,
                vertexColors.allSatisfy({ color in (0..<4).allSatisfy { color[$0].isFinite && color[$0] >= 0 } }) else { throw TriangleGeometryError.invalidInput }
        }
        guard !parts.isEmpty, parts.count <= 512 else { throw TriangleGeometryError.invalidInput }
        var first: UInt64 = 0
        for part in parts {
            guard part.firstFace == first, part.faceCount > 0 else { throw TriangleGeometryError.invalidInput }
            first += UInt64(part.faceCount)
            try part.material.validate()
        }
        guard first == faceCount else { throw TriangleGeometryError.invalidInput }
    }

    public func group(for face: UInt32) -> Int? {
        var low = 0, high = parts.count
        while low < high {
            let mid = (low + high) / 2
            if parts[mid].firstFace <= face { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let group = low - 1
        return face - parts[group].firstFace < parts[group].faceCount ? group : nil
    }
}
