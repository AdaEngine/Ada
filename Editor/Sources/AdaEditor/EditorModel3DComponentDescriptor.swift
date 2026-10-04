@_spi(AdaEngine) import AdaEngine
import Foundation

extension EditorComponentRegistry {
    static let model3DSourceDescriptor = EditorComponentDescriptor(
        typeName: EditorBuiltInComponentType.model3DSource,
        displayName: "Model 3D",
        category: "3D",
        description: "Imports a GLB or glTF model with its hierarchy, materials and named animations.",
        requiredComponentTypeNames: [EditorBuiltInComponentType.transform],
        fields: [
            EditorComponentField(key: "source", label: "Model", kind: .assetReference),
            EditorComponentField(key: "animation", label: "Animation name", kind: .string),
            EditorComponentField(key: "autoplay", label: "Play animation", kind: .bool),
            EditorComponentField(key: "repeats", label: "Loop animation", kind: .bool),
        ],
        makeDefaultPayload: { ["source": .string(""), "animation": .string(""), "autoplay": .bool(false), "repeats": .bool(true)] },
        decode: { payload in
            Model3DSource(
                source: payload["source"]?.stringValue ?? "",
                animation: payload["animation"]?.stringValue ?? "",
                autoplay: payload["autoplay"]?.boolValue ?? false,
                repeats: payload["repeats"]?.boolValue ?? true
            )
        }
    )
}

enum EditorModelResource {
    static let extensions: Set<String> = ["glb", "gltf"]

    static func resolve(_ reference: String, sourceURL: URL?, resourceRootURL: URL?) throws -> URL {
        let url: URL
        if reference.hasPrefix("@res://"), let resourceRootURL {
            url = resourceRootURL.appendingPathComponent(String(reference.dropFirst("@res://".count)))
        } else if !reference.hasPrefix("@res://"), let sourceURL {
            url = URL(fileURLWithPath: reference, relativeTo: sourceURL.deletingLastPathComponent())
        } else {
            throw AssetError.message("Unable to resolve model '\(reference)'.")
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        if let resourceRootURL {
            let root = resourceRootURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.path.hasPrefix(root + "/") else { throw AssetError.message("Model must be inside project assets.") }
        }
        guard extensions.contains(resolved.pathExtension.lowercased()), FileManager.default.fileExists(atPath: resolved.path) else {
            throw AssetError.message("Model is missing or is not a GLB/glTF file: \(reference)")
        }
        return resolved
    }
}
