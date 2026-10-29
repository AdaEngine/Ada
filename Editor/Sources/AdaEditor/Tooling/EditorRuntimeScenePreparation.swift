import AdaEngine
import AdaSpine
import Foundation

/// Prepares a replacement without blocking the current scene's UI. Handles must
/// stay alive through instantiation: the asset cache tracks handle lifetimes.
struct EditorRuntimeScenePreparation: Sendable {
    let model: EditorSceneModel
    private let models: [AssetHandle<ModelAsset3D>]
    private let skeletons: [AssetHandle<SpineSkeleton>]

    @concurrent
    static func prepare(
        at url: URL,
        assetsDirectory: URL,
        reportProgress: @escaping @Sendable (SceneNavigator.LoadingProgress) -> Void = { _ in }
    ) async throws -> Self {
        reportProgress(.init(fraction: 0, stage: "reading"))
        var paths = Paths()
        let model = try collect(at: url, assetsDirectory: assetsDirectory, ancestry: [], paths: &paths)
        var models: [AssetHandle<ModelAsset3D>] = []
        var skeletons: [AssetHandle<SpineSkeleton>] = []
        let total = max(1, paths.models.count + paths.skeletons.count)
        var completed = 0
        reportProgress(.init(fraction: 0.05, stage: "assets"))
        // Keep imports bounded rather than decoding every GLB/texture at once.
        // Async asset loading runs on its asset executor, not the main actor.
        for path in paths.models.sorted() {
            try Task.checkCancellation()
            let handle = try await AssetsManager.load(ModelAsset3D.self, at: path)
            guard handle.asset != nil else { throw AssetError.message("Model has not loaded: \(path)") }
            models.append(handle)
            completed += 1
            reportProgress(.init(fraction: 0.05 + 0.9 * Double(completed) / Double(total), stage: "assets"))
        }
        for path in paths.skeletons.sorted() {
            try Task.checkCancellation()
            let handle = try await AssetsManager.load(SpineSkeleton.self, at: path)
            guard handle.asset != nil else { throw AssetError.message("Spine skeleton has not loaded: \(path)") }
            skeletons.append(handle)
            completed += 1
            reportProgress(.init(fraction: 0.05 + 0.9 * Double(completed) / Double(total), stage: "assets"))
        }
        try Task.checkCancellation()
        reportProgress(.init(fraction: 0.95, stage: "installing"))
        return Self(model: model, models: models, skeletons: skeletons)
    }

    private struct Paths {
        var models: Set<String> = []
        var skeletons: Set<String> = []
    }

    private static func collect(at url: URL, assetsDirectory: URL, ancestry: Set<URL>, paths: inout Paths) throws -> EditorSceneModel {
        try Task.checkCancellation()
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        guard !ancestry.contains(url) else { throw AssetError.message("Nested scene cycle: \(url.path)") }
        let model = try EditorSceneModel.decode(from: String(contentsOf: url, encoding: .utf8))
        var ancestry = ancestry;ancestry.insert(url)
        for entity in model.entities {
            if let payload = entity.components[EditorBuiltInComponentType.model3DSource],
               let source = payload["source"]?.stringValue, !source.isEmpty {
                let resolved = try EditorModelResource.resolve(source, sourceURL: url, resourceRootURL: assetsDirectory).path
                let voxel: VoxelImportSettings?
                if let value = payload["voxel"] {
                    voxel = try JSONDecoder().decode(VoxelImportSettings.self, from: JSONEncoder().encode(value))
                } else { voxel = nil }
                paths.models.insert(Model3DSource(source: resolved, voxel: voxel).assetPath)
                if case let .object(lod) = payload["lod"], case let .array(sources) = lod["sources"] {
                    for source in sources {
                        paths.models.insert(try EditorModelResource.resolve(source.stringValue, sourceURL: url, resourceRootURL: assetsDirectory).path)
                    }
                }
            }
            if let source = entity.components[EditorBuiltInComponentType.spineSource]?["source"]?.stringValue, !source.isEmpty {
                paths.skeletons.insert(try EditorSpineResource.resolve(source, sourceURL: url, resourceRootURL: assetsDirectory).path)
            }
            if let source = entity.components[EditorBuiltInComponentType.sceneInstance]?["scene"]?.stringValue, !source.isEmpty {
                let nested: URL
                if source.hasPrefix("@res://") { nested = assetsDirectory.appendingPathComponent(String(source.dropFirst(7))) }
                else { nested = url.deletingLastPathComponent().appendingPathComponent(source) }
                let canonical = nested.resolvingSymlinksInPath().standardizedFileURL
                let root = assetsDirectory.resolvingSymlinksInPath().standardizedFileURL.path
                guard canonical.path.hasPrefix(root + "/"), canonical.pathExtension == "ascn" else {
                    throw AssetError.message("Nested scene must be inside project assets: \(source)")
                }
                _ = try collect(at: canonical, assetsDirectory: assetsDirectory, ancestry: ancestry, paths: &paths)
            }
        }
        return model
    }
}
