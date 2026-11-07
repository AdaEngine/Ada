import Foundation

/// A stable palette entry. Paths are portable, relative to the manifest directory.
public struct TerrainMeshPrototypeReference: Codable, Equatable, Sendable {
    public let id: UInt16
    public let assetPath: String
    public let scene: Int?
    /// Optional world-space draw distance; nil retains the instance at every distance.
    public let maximumDistance: Float?

    public init(id: UInt16, assetPath: String, scene: Int? = nil, maximumDistance: Float? = nil) {
        self.id = id; self.assetPath = assetPath; self.scene = scene; self.maximumDistance = maximumDistance
    }

    func validate() throws {
        let components = assetPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !assetPath.isEmpty, assetPath.utf8.count <= 512,
            !assetPath.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || "\\:%?#\"<>|*".unicodeScalars.contains($0) }),
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 128 && $0.last != "." && $0.last != " " }),
            ["gltf", "glb", "obj", "vox"].contains(URL(fileURLWithPath: assetPath).pathExtension.lowercased()),
            scene.map({ (0..<4_096).contains($0) }) ?? true,
            maximumDistance.map({ $0.isFinite && $0 > 0 }) ?? true
        else { throw TerrainManifestError.malformed("invalid static model palette reference") }
    }
}
