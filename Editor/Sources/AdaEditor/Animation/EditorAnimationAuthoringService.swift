import AdaEngine
import Foundation
import Observation

/// One project-owned authoring service. No VM or agent receives editor model references.
@Observable
@MainActor
final class EditorAnimationAuthoringService {
    let projectURL: URL
    let assetsURL: URL
    private(set) var documents: [String: EditorAnimationLibraryDocument] = [:]
    var modifierDocuments: [String: EditorAnimationModifierDocument] = [:]
    @ObservationIgnored var onDocumentOpened: ((EditorAnimationLibraryDocument) -> Void)?
    @ObservationIgnored var onModifierDocumentOpened: ((EditorAnimationModifierDocument) -> Void)?
    @ObservationIgnored var onModifierDocumentDiscarded: ((EditorAnimationModifierDocument) -> Void)?
    @ObservationIgnored var onDocumentDiscarded: ((String) -> Void)?
    @ObservationIgnored private var generation = UUID()
    nonisolated static let maximumBytes = 32 * 1024 * 1024

    init(projectURL: URL, assetsURL: URL) {
        self.projectURL = projectURL.resolvingSymlinksInPath().standardizedFileURL
        self.assetsURL = assetsURL.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Resolves a project-relative path, including new destinations, under the configured Assets root.
    func resolve(_ path: String, extensions: Set<String>) throws -> URL {
        guard !path.isEmpty, !path.contains(":"), !path.contains("\\"), !path.hasPrefix("/"),
            !path.contains("#"), !path.contains("?"), !path.contains("\0"),
            projectURL.resolvingSymlinksInPath().standardizedFileURL.path == projectURL.path,
            assetsURL.resolvingSymlinksInPath().standardizedFileURL.path == assetsURL.path else { throw invalidPath(path) }
        let target = Self.canonicalDestination(projectURL.appendingPathComponent(path))
        guard assetsURL.path.hasPrefix(projectURL.path + "/"), target.path.hasPrefix(assetsURL.path + "/"),
            extensions.contains(target.pathExtension.lowercased()) else { throw invalidPath(path) }
        return target
    }

    /// Foundation on Windows leaves a missing leaf unresolved, even when its parent is a symlink.
    /// Resolve an existing ancestor first so new destinations receive the same confinement checks.
    nonisolated static func canonicalDestination(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent != ancestor else { break }
            suffix.append(ancestor.lastPathComponent)
            ancestor = parent
        }
        var result = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in suffix.reversed() { result.appendPathComponent(component) }
        return result.standardizedFileURL
    }

    func open(_ path: String) throws -> EditorAnimationLibraryDocument {
        let url = try resolve(path, extensions: ["animlib"])
        if let document = documents[url.path] { return document }
        let data = try Self.readBounded(url, resourceRoot: assetsURL)
        let document = try EditorAnimationLibraryDocument(url: url, relativePath: relative(url), library: AnimationLibrary.decode(data), savedBytes: data, resourceRoot: assetsURL)
        documents[url.path] = document
        onDocumentOpened?(document)
        return document
    }

    func create(_ path: String, library: AnimationLibrary) throws -> EditorAnimationLibraryDocument {
        let url = try resolve(path, extensions: ["animlib"])
        guard documents[url.path] == nil, !FileManager.default.fileExists(atPath: url.path) else {
            throw AnimationAuthoringError(.conflict, itemID: path, message: "Animation resource already exists; inspect and edit it instead.")
        }
        let document = try EditorAnimationLibraryDocument(url: url, relativePath: relative(url), library: library, savedBytes: nil, resourceRoot: assetsURL)
        documents[url.path] = document
        onDocumentOpened?(document)
        return document
    }

    /// CPU import runs outside the UI actor. Publishing rechecks the resource revision after suspension.
    func extract(path: String, modelPath: String, clipName: String?, name: String?, expectedRevision: String? = nil) async throws -> EditorAnimationLibraryDocument {
        let token = generation
        let destination = try resolve(path, extensions: ["animlib"])
        let modelURL = try resolve(modelPath, extensions: ["glb", "gltf"])
        let existing: EditorAnimationLibraryDocument?
        if FileManager.default.fileExists(atPath: destination.path) || documents[destination.path] != nil {
            existing = try open(path)
            try existing?.checkRevision(expectedRevision ?? "")
        } else { existing = nil }
        let imported = try await Self.importLibrary(modelURL: modelURL, assetsURL: assetsURL, source: relative(modelURL), clipName: clipName, name: name)
        try Task.checkCancellation()
        guard generation == token, try resolve(path, extensions: ["animlib"]) == destination,
            try resolve(modelPath, extensions: ["glb", "gltf"]) == modelURL else {
            throw AnimationAuthoringError(.conflict, itemID: path, message: "Project resources changed during import; retry.")
        }
        if let existing {
            try existing.checkRevision(expectedRevision ?? "")
            guard existing.library.binding == imported.binding else {
                throw AnimationAuthoringError(.incompatibleRig, itemID: path, message: "Source rig differs from this library; remap explicitly.")
            }
            var draft = existing.library
            draft.clips.append(contentsOf: imported.clips)
            try existing.commit(draft, expectedRevision: expectedRevision ?? "")
            return existing
        }
        return try create(path, library: imported)
    }

    func apply(path: String, expectedRevision: String, operations: [AnimationEdit]) throws -> EditorAnimationLibraryDocument {
        let document = try open(path)
        try document.apply(operations, expectedRevision: expectedRevision)
        return document
    }

    func close(_ path: String) throws {
        let url = try resolve(path, extensions: ["animlib"])
        guard documents[url.path]?.isDirty != true else {
            throw AnimationAuthoringError(.conflict, itemID: path, message: "Save or explicitly discard the animation draft before closing it.")
        }
        generation = UUID()
        documents.removeValue(forKey: url.path)?.discard()
    }

    /// Explicit discard/project deletion invalidates suspended imports and removes stale cached drafts.
    func discardDocuments(atOrBelow path: String) {
        generation = UUID()
        for (key, document) in documents where document.relativePath == path || document.relativePath.hasPrefix(path + "/") {
            document.discard()
            documents.removeValue(forKey: key)
        }
        for (key, document) in modifierDocuments where document.relativePath == path || document.relativePath.hasPrefix(path + "/") {
            document.discard()
            modifierDocuments.removeValue(forKey: key)
            onModifierDocumentDiscarded?(document)
        }
    }

    func invalidatePendingWork() { generation = UUID() }

    func requestGeneration() -> UUID { generation }

    func checkGeneration(_ expected: UUID) throws {
        guard generation == expected else {
            throw AnimationAuthoringError(.conflict, itemID: "project", message: "The project authoring session changed; inspect and retry.")
        }
    }

    func discard(_ document: EditorAnimationLibraryDocument, expectedRevision: String, discardChanges: Bool) throws {
        guard documents[document.url.path] === document, document.revision == expectedRevision, discardChanges else {
            throw AnimationAuthoringError(.conflict, itemID: document.relativePath, message: "Discard needs the current revision and explicit discardChanges: true.")
        }
        discardDocuments(atOrBelow: document.relativePath)
        onDocumentDiscarded?(document.relativePath)
    }

    func reload(_ document: EditorAnimationLibraryDocument, expectedRevision: String, discardChanges: Bool = false) throws {
        let url = try resolve(document.relativePath, extensions: ["animlib"])
        guard documents[url.path] === document else { throw invalidPath(document.relativePath) }
        try document.reload(Self.readBounded(url, resourceRoot: assetsURL), expectedRevision: expectedRevision, discardChanges: discardChanges)
    }

    func savedDocuments(references: [String], sceneURL: URL?) throws -> [EditorAnimationLibraryDocument] {
        var seen: Set<URL> = []
        return try references.map { reference in
            guard let url = EditorSceneFileLoader.resolveTileMapReference(reference, relativeTo: sceneURL, resourceRootURL: assetsURL, fileExtension: "animlib"),
                seen.insert(url).inserted else {
                throw AnimationAuthoringError(.conflict, itemID: reference, message: "Use distinct animation resources inside project assets.")
            }
            let document = try open(relative(url))
            try document.requireSavedSnapshot()
            return document
        }
    }

    struct ModelAnimations: Sendable { let rig: SkeletalRig; let clips: [SkeletalAnimationClip] }

    func animationsForModel(_ path: String) async throws -> ModelAnimations {
        let token = generation
        let url = try resolve(path, extensions: ["glb", "gltf"])
        let result = try await Self.readAnimations(modelURL: url, assetsURL: assetsURL)
        try Task.checkCancellation()
        guard generation == token, try resolve(path, extensions: ["glb", "gltf"]) == url else {
            throw AnimationAuthoringError(.conflict, itemID: path, message: "Model changed while loading animation bindings.")
        }
        return result
    }

    func rigForModel(_ path: String) async throws -> SkeletalRig {
        try await animationsForModel(path).rig
    }

    @concurrent
    private static func readAnimations(modelURL: URL, assetsURL: URL) async throws -> ModelAnimations {
        try Task.checkCancellation()
        let imported = try NativeGLTFLoader(resourceRoot: assetsURL, maximumTotalBytes: maximumBytes)
            .load(data: readBounded(modelURL, resourceRoot: assetsURL), baseURL: modelURL.deletingLastPathComponent())
        try Task.checkCancellation()
        return try .init(rig: GLTFAnimationAdapter.makeRig(nodes: imported.nodes, meshes: imported.meshes),
                         clips: GLTFAnimationAdapter.makeClips(imported.animations, nodes: imported.nodes, meshes: imported.meshes))
    }

    @concurrent
    private static func importLibrary(modelURL: URL, assetsURL: URL, source: String, clipName: String?, name: String?) async throws -> AnimationLibrary {
        try Task.checkCancellation()
        let data = try readBounded(modelURL, resourceRoot: assetsURL)
        let imported = try NativeGLTFLoader(resourceRoot: assetsURL, maximumTotalBytes: maximumBytes)
            .load(data: data, baseURL: modelURL.deletingLastPathComponent())
        let rig = try GLTFAnimationAdapter.makeRig(nodes: imported.nodes, meshes: imported.meshes)
        var library = AnimationLibrary(binding: .init(rig: rig, sourceAsset: source))
        if let clipName {
            let clips = try GLTFAnimationAdapter.makeClips(imported.animations, nodes: imported.nodes, meshes: imported.meshes)
            let matches = clips.filter { $0.name == clipName }
            guard matches.count == 1, let clip = matches.first else {
                throw AnimationAuthoringError(.missingClip, itemID: clipName, message: "Choose one exact, unambiguous imported clip name.")
            }
            try library.extract(clip, rig: rig, name: name, sourceFingerprint: EditorAgentSceneToolService.revision(for: data.base64EncodedString()))
        } else {
            library.clips = [try library.poseClip(name: name ?? "Animation", duration: 1)]
        }
        try Task.checkCancellation()
        return library
    }

    private nonisolated static func readBounded(_ url: URL, resourceRoot: URL) throws -> Data {
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.path,
            resourceRoot.resolvingSymlinksInPath().standardizedFileURL.path == resourceRoot.path,
            url.path.hasPrefix(resourceRoot.path + "/") else {
            throw AnimationAuthoringError(.conflict, itemID: url.lastPathComponent, message: "Resource location changed outside project assets.")
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else {
            throw AnimationAuthoringError(.limitExceeded, itemID: url.lastPathComponent, message: "Animation/model documents must be at most 32 MiB.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw AnimationAuthoringError(.limitExceeded, itemID: url.lastPathComponent, message: "Document grew beyond 32 MiB while reading it.")
        }
        return data
    }

    private func relative(_ url: URL) -> String { String(url.path.dropFirst(projectURL.path.count + 1)) }

    private func invalidPath(_ path: String) -> AnimationAuthoringError {
        .init(.missingTarget, itemID: path, message: "Use a project-relative resource path inside Assets with a supported extension.")
    }
}
