@_spi(AdaEngine) import AdaEngine
import Foundation

/// The scene stores a portable reference; runtime budgets retain their engine defaults.
enum EditorTerrainSourcePayload {
    static func encode(_ source: Terrain3DSource) -> EditorComponentPayload {
        (try? JSONDecoder().decode(EditorComponentPayload.self, from: JSONEncoder().encode(source))) ?? [:]
    }

    static func decode(_ payload: EditorComponentPayload) throws -> Terrain3DSource {
        // Missing optional fields keep Codable semantics; defaults fill required fields only.
        var complete = encode(Terrain3DSource(streamingRadius: nil))
        complete.merge(payload) { _, authored in authored }
        return try JSONDecoder().decode(Terrain3DSource.self, from: JSONEncoder().encode(complete))
    }
}

extension EditorComponentRegistry {
    static let terrainSourceDescriptor: EditorComponentDescriptor = {
        var color = EditorComponentField(key: "color", label: "Ground Color", kind: .vector4)
        color.coding = .vectorObject
        return EditorComponentDescriptor(
            typeName: EditorBuiltInComponentType.terrain3DSource,
            displayName: "Terrain Source",
            category: "3D",
            description: "A saved terrain with chunks, caves and overhangs.",
            requiredComponentTypeNames: [EditorBuiltInComponentType.transform, EditorBuiltInComponentType.visibility],
            fields: [
                EditorComponentField(key: "source", label: "Terrain File", kind: .assetReference),
                color,
                EditorComponentField(key: "generatesCollision", label: "Ground Collision", kind: .bool),
            ],
            makeDefaultPayload: { EditorTerrainSourcePayload.encode(Terrain3DSource()) },
            decode: { try EditorTerrainSourcePayload.decode($0) }
        )
    }()
}

@MainActor
enum EditorTerrainResource {
    static func resolve(_ reference: String, sourceURL: URL?, resourceRootURL: URL?) throws -> URL {
        guard let root = resourceRootURL ?? sourceURL?.deletingLastPathComponent() else {
            throw AssetError.message(L10n.text("Open a project scene before choosing a terrain file."))
        }
        let url: URL
        if reference.hasPrefix("@res://") {
            url = root.appendingPathComponent(String(reference.dropFirst(7)))
        } else if let sourceURL {
            url = URL(fileURLWithPath: reference, relativeTo: sourceURL.deletingLastPathComponent())
        } else {
            throw AssetError.message(L10n.text("Choose an existing .aterrain file from project Assets."))
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(canonicalRoot.path + "/") else {
            throw AssetError.message(L10n.text("Terrain files must be inside project Assets."))
        }
        var isDirectory: ObjCBool = false
        guard resolved.pathExtension.lowercased() == "aterrain",
            FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AssetError.message(L10n.text("Choose an existing .aterrain file from project Assets."))
        }
        return resolved
    }
}
