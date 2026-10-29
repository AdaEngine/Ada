import AdaEngine
import AdaSpine
import Foundation

/// Strong ownership belongs to the preview world, not the weak global handle index.
/// A reload retains only resources referenced by the replacement scene.
struct EditorSceneAssetCache: Resource {
    private(set) var models: [String: AssetHandle<ModelAsset3D>] = [:]
    private(set) var skeletons: [String: AssetHandle<SpineSkeleton>] = [:]
    private var failures: [String: String] = [:]
    private var revisions: [String: FileRevision] = [:]
    private var usedModels: Set<String> = []
    private var usedSkeletons: Set<String> = []

    mutating func beginLoad() {
        usedModels.removeAll(keepingCapacity: true)
        usedSkeletons.removeAll(keepingCapacity: true)
    }

    mutating func finishLoad() {
        models = models.filter { usedModels.contains($0.key) }
        skeletons = skeletons.filter { usedSkeletons.contains($0.key) }
        failures.removeAll()
        revisions = revisions.filter { usedModels.contains($0.key) || usedSkeletons.contains($0.key) }
    }

    mutating func model(at path: String) throws -> ModelAsset3D {
        usedModels.insert(path)
        if let failure = failures[path] { throw AssetError.message(failure) }
        let revision = FileRevision(path: path)
        if revisions[path] == revision, let handle = models[path], let asset = handle.asset { return asset }
        #if WASM
        throw AssetError.message("Model has not loaded.")
        #else
        let handle = try models[path] == nil
            ? AssetsManager.loadSync(ModelAsset3D.self, at: path)
            : AssetHandle(AssetsManager.loadFreshSync(ModelAsset3D.self, at: path))
        guard let asset = handle.asset else { throw AssetError.message("Model has not loaded: \(path)") }
        models[path] = handle
        revisions[path] = revision
        return asset
        #endif
    }

    mutating func skeleton(at path: String) throws -> SpineSkeleton {
        usedSkeletons.insert(path)
        if let failure = failures[path] { throw AssetError.message(failure) }
        let revision = FileRevision(path: path)
        if revisions[path] == revision, let handle = skeletons[path], let asset = handle.asset { return asset }
        #if WASM
        throw AssetError.message("Spine skeleton has not loaded.")
        #else
        let handle = try skeletons[path] == nil
            ? AssetsManager.loadSync(SpineSkeleton.self, at: path)
            : AssetHandle(AssetsManager.loadFreshSync(SpineSkeleton.self, at: path))
        guard let asset = handle.asset else { throw AssetError.message("Spine skeleton has not loaded: \(path)") }
        skeletons[path] = handle
        revisions[path] = revision
        return asset
        #endif
    }

    /// Decode/import off the UI actor, sequentially to bound temporary import memory.
    /// Invalid assets remain per-entity warnings instead of preventing the scene from opening.
    @concurrent
    static func prepare(
        model: EditorSceneModel,
        sourceURL: URL?,
        resourceRootURL: URL?,
        reusing previous: Self = Self()
    ) async throws -> Self {
        var paths = Paths()
        try collect(model: model, sourceURL: sourceURL, resourceRootURL: resourceRootURL, ancestry: [], paths: &paths)
        var result = Self()
        for path in paths.models.sorted() {
            try Task.checkCancellation()
            do {
                let revision = FileRevision(path: path)
                if previous.revisions[path] == revision, let handle = previous.models[path], handle.asset != nil {
                    result.models[path] = handle
                } else if previous.models[path] != nil {
                    result.models[path] = AssetHandle(try await AssetsManager.loadFresh(ModelAsset3D.self, at: path))
                } else {
                    result.models[path] = try await AssetsManager.load(ModelAsset3D.self, at: path)
                }
                result.revisions[path] = revision
            } catch {
                result.failures[path] = error.localizedDescription
            }
        }
        for path in paths.skeletons.sorted() {
            try Task.checkCancellation()
            do {
                let revision = FileRevision(path: path)
                if previous.revisions[path] == revision, let handle = previous.skeletons[path], handle.asset != nil {
                    result.skeletons[path] = handle
                } else if previous.skeletons[path] != nil {
                    result.skeletons[path] = AssetHandle(try await AssetsManager.loadFresh(SpineSkeleton.self, at: path))
                } else {
                    result.skeletons[path] = try await AssetsManager.load(SpineSkeleton.self, at: path)
                }
                result.revisions[path] = revision
            } catch {
                result.failures[path] = error.localizedDescription
            }
        }
        try Task.checkCancellation()
        return result
    }

    private struct Paths {
        var models: Set<String> = []
        var skeletons: Set<String> = []
    }

    private struct FileRevision: Equatable, Sendable {
        let modified: Date?
        let size: Int?

        init(path: String) {
            let file = String(path.prefix { $0 != "#" })
            let values = try? URL(fileURLWithPath: file).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            modified = values?.contentModificationDate
            size = values?.fileSize
        }
    }

    private static func collect(
        model: EditorSceneModel, sourceURL: URL?, resourceRootURL: URL?, ancestry: Set<URL>, paths: inout Paths
    ) throws {
        try Task.checkCancellation()
        var ancestry = ancestry
        if let sourceURL { ancestry.insert(sourceURL.resolvingSymlinksInPath().standardizedFileURL) }
        for entity in model.entities {
            if let payload = entity.components[EditorBuiltInComponentType.model3DSource],
               let source = payload["source"]?.stringValue, !source.isEmpty,
               let url = try? EditorModelResource.resolve(source, sourceURL: sourceURL, resourceRootURL: resourceRootURL) {
                let voxel = payload["voxel"].flatMap { try? JSONDecoder().decode(VoxelImportSettings.self, from: JSONEncoder().encode($0)) }
                paths.models.insert(Model3DSource(source: url.path, voxel: voxel).assetPath)
                if case let .object(lod) = payload["lod"], case let .array(sources) = lod["sources"] {
                    for source in sources {
                        if let url = try? EditorModelResource.resolve(source.stringValue, sourceURL: sourceURL, resourceRootURL: resourceRootURL) {
                            paths.models.insert(url.path)
                        }
                    }
                }
            }
            if let source = entity.components[EditorBuiltInComponentType.spineSource]?["source"]?.stringValue, !source.isEmpty,
               let url = try? EditorSpineResource.resolve(source, sourceURL: sourceURL, resourceRootURL: resourceRootURL) {
                paths.skeletons.insert(url.path)
            }
            if let reference = entity.components[EditorBuiltInComponentType.sceneInstance]?["scene"]?.stringValue,
               let url = EditorSceneFileLoader.resolveSceneReference(reference, relativeTo: sourceURL, resourceRootURL: resourceRootURL),
               !ancestry.contains(url),
               let nested = try? EditorSceneModel.decode(from: String(contentsOf: url, encoding: .utf8)) {
                try collect(model: nested, sourceURL: url, resourceRootURL: resourceRootURL, ancestry: ancestry, paths: &paths)
            }
        }
    }
}
