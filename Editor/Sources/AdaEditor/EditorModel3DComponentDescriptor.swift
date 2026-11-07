@_spi(AdaEngine) import AdaEngine
import Foundation

extension EditorComponentRegistry {
    static let model3DSourceDescriptor = EditorComponentDescriptor(
        typeName: EditorBuiltInComponentType.model3DSource,
        displayName: "Model 3D",
        category: "3D",
        description: "Imports a GLB, glTF or MagicaVoxel (.vox) model with its hierarchy, materials and animations.",
        requiredComponentTypeNames: [EditorBuiltInComponentType.transform],
        fields: [
            EditorComponentField(key: "source", label: "Model", kind: .assetReference),
            EditorComponentField(key: "animation", label: "Animation name", kind: .string),
            EditorComponentField(key: "autoplay", label: "Play animation", kind: .bool),
            EditorComponentField(key: "repeats", label: "Loop animation", kind: .bool),
            voxelField("voxelSize", "Voxel size (.vox)", .float, defaultValue: .double(Double("\(VoxelImportSettings.defaultVoxelSize)") ?? 0.1), minimumValue: 0.001),
            voxelField("voxelMergeStatic", "Merge static voxels (.vox)", .bool, defaultValue: .bool(false)),
            voxelField("voxelFramesPerSecond", "Voxel animation fps (.vox)", .float, defaultValue: .double(VoxelImportSettings.defaultFramesPerSecond), minimumValue: 1),
        ],
        makeDefaultPayload: { ["source": .string(""), "animation": .string(""), "autoplay": .bool(false), "repeats": .bool(true)] },
        decode: { payload in
            var source = Model3DSource(
                source: payload["source"]?.stringValue ?? "",
                animation: payload["animation"]?.stringValue ?? "",
                autoplay: payload["autoplay"]?.boolValue ?? false,
                repeats: payload["repeats"]?.boolValue ?? true,
                animationGraph: try EditorAnimationGraphPayload.decode(payload["animationGraph"]),
                lod: try payload["lod"].flatMap { value in
                    if case .null = value { return nil }
                    return try JSONDecoder().decode(Model3DSourceLOD.self, from: Data(value.jsonString.utf8))
                },
                voxel: voxelSettings(in: payload),
                morphWeights: EditorMorphWeightsPayload.decode(payload["morphWeights"]),
                animationLibraries: try payload["animationLibraries"].map { try JSONDecoder().decode([String].self, from: JSONEncoder().encode($0)) } ?? []
            )
            if let path = payload["animationModifiers"]?.stringValue, !path.isEmpty { source.animationModifiers = path }
            if let bindings = payload["modifierBindings"], bindings != .null {
                source.modifierBindings = try JSONDecoder().decode([String: AnimationIKBinding3D].self, from: JSONEncoder().encode(bindings))
            }
            if let overrides = payload["graphMaterials"], overrides != .null {
                source.graphMaterials = try JSONDecoder().decode(
                    [String: ShaderGraphMaterialSource].self, from: JSONEncoder().encode(overrides)
                )
            }
            return source
        }
    )

    private static func voxelField(
        _ key: String,
        _ label: String,
        _ kind: EditorComponentFieldKind,
        defaultValue: EditorSceneValue,
        minimumValue: Double? = nil
    ) -> EditorComponentField {
        var field = EditorComponentField(key: key, label: label, kind: kind)
        field.defaultValue = defaultValue
        field.minimumValue = minimumValue
        return field
    }

    /// Settings authored on the component; `nil` while every value is at its default so plain scenes stay unchanged.
    private static func voxelSettings(in payload: EditorComponentPayload) -> VoxelImportSettings? {
        let settings = VoxelImportSettings(
            voxelSize: payload["voxelSize"]?.doubleValue.map { Float($0) } ?? VoxelImportSettings.defaultVoxelSize,
            mergeStatic: payload["voxelMergeStatic"]?.boolValue ?? false,
            framesPerSecond: payload["voxelFramesPerSecond"]?.doubleValue ?? VoxelImportSettings.defaultFramesPerSecond
        )
        return settings.isDefault ? nil : settings
    }
}

enum EditorModelResource {
    /// Every format Model 3D can load: glTF models and MagicaVoxel scenes.
    static let extensions: Set<String> = ["glb", "gltf", "vox"]
    /// Formats with glTF structure (JSON document, buffers, skins) for glTF-specific tooling.
    static let gltfExtensions: Set<String> = ["glb", "gltf"]
    static let voxelExtension = "vox"

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
            throw AssetError.message("Model is missing or is not a GLB, glTF or VOX file: \(reference)")
        }
        return resolved
    }
}
