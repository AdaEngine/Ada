@_spi(AdaEngine) import AdaEngine
import AdaPackageManifestTool
import Foundation
import Observation

private struct EditorProjectTreeEntry {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
}

private let editorProjectSkippedNames: Set<String> = [".ada", ".builds", ".DS_Store", ".git", ".lore", ".swiftpm", "DerivedData"]
private let editorProjectTextExtensions: Set<String> = [
    "ada", "c", "cc", "comp", "cpp", "cxx", "frag", "geom", "glsl", "gravity", "h", "hpp", "hxx", "json", "md", "markdown",
    "ui", "ascn", "tileset", "metal", "plist", "scn", "scene", "shader", "strings", "swift", "tesc", "tese", "toml", "txt", "vert", "wgsl", "xml", "yaml", "yml",
]

extension EditorViewModel {
    static func projectTreeItems(for project: EditorProjectReference?, fileManager: FileManager) -> [EditorProjectSidebarViewModel.Item] {
        guard let project else {
            return EditorProjectSidebarViewModel().items
        }

        let projectURL = URL(fileURLWithPath: project.path, isDirectory: true)
        return buildProjectTreeItems(at: projectURL, fileManager: fileManager)
    }

    nonisolated static func document(for item: EditorProjectSidebarViewModel.Item) -> EditorWorkbenchDocument {
        if URL(fileURLWithPath: item.title).pathExtension.lowercased() == "ui" {
            let content = textFileContent(for: item)
            return .ui(
                EditorTextDocument(
                    id: "ui:\(item.relativePath)",
                    title: item.title,
                    relativePath: item.relativePath,
                    absolutePath: absoluteFilePath(from: item.id),
                    language: .plainText,
                    content: content.value,
                    lastSavedContent: content.errorMessage == nil ? content.value : nil,
                    isReadOnly: item.isSymbolicLink || content.errorMessage != nil,
                    errorMessage: content.errorMessage
                )
            )
        }
        switch item.kind {
        case .scene:
            let content = sceneFileContent(for: item)
            let defersDecode = content.errorMessage == nil && content.value.utf8.count > 256 * 1_024
            let sceneModel = defersDecode ? nil : EditorSceneFileLoader.model(from: content.value)
            return .scene(
                EditorSceneDocument(
                    id: "scene:\(item.relativePath)",
                    title: item.title,
                    relativePath: item.relativePath,
                    absolutePath: absoluteFilePath(from: item.id),
                    content: content.value,
                    lastSavedContent: content.errorMessage == nil ? content.value : nil,
                    isReadOnly: item.isSymbolicLink,
                    isLoading: defersDecode,
                    sceneModel: sceneModel,
                    errorMessage: content.errorMessage,
                    isDirty: false,
                    statusMessage: item.isSymbolicLink ? "Read-only: symbolic link" : content.errorMessage == nil ? "Loaded" : nil,
                    loadSummary: sceneModel.map { EditorSceneLoadSummary(entityCount: $0.entities.count, warnings: []) }
                        ?? (defersDecode ? .empty : EditorSceneFileLoader.summary(from: content.value))
                )
            )
        case let .text(language):
            let content = textFileContent(for: item)
            return .text(
                EditorTextDocument(
                    id: "text:\(item.relativePath)",
                    title: item.title,
                    relativePath: item.relativePath,
                    absolutePath: absoluteFilePath(from: item.id),
                    language: language,
                    content: content.value,
                    lastSavedContent: content.errorMessage == nil ? content.value : nil,
                    isReadOnly: item.isSymbolicLink || content.errorMessage != nil,
                    errorMessage: content.errorMessage,
                    statusMessage: item.isSymbolicLink ? "Read-only: symbolic link" : content.errorMessage == nil ? nil : "Read-only: unable to read as UTF-8"
                )
            )
        case .image,
            .audio,
            .genericAsset:
            return .asset(assetDocument(for: item))
        case .folder,
            .unsupported:
            return .text(
                EditorTextDocument(
                    id: "unsupported:\(item.relativePath)",
                    title: item.title,
                    relativePath: item.relativePath,
                    language: .plainText,
                    content: "Preview is not available for this file.",
                    errorMessage: nil
                )
            )
        }
    }

    nonisolated static func textFileContent(for item: EditorProjectSidebarViewModel.Item) -> (value: String, errorMessage: String?) {
        guard let absolutePath = absoluteFilePath(from: item.id) else {
            return (AdaEngineStyleContent.sampleTextDocuments[item.relativePath] ?? "", nil)
        }

        do {
            return (try String(contentsOf: URL(fileURLWithPath: absolutePath, isDirectory: false), encoding: .utf8), nil)
        } catch {
            return ("", error.localizedDescription)
        }
    }

    nonisolated static func sceneFileContent(for item: EditorProjectSidebarViewModel.Item) -> (value: String, errorMessage: String?) {
        guard let absolutePath = absoluteFilePath(from: item.id) else {
            return (SceneDocumentFormat.defaultSceneYAML(projectName: item.title), nil)
        }

        do {
            return (try String(contentsOf: URL(fileURLWithPath: absolutePath), encoding: .utf8), nil)
        } catch {
            return ("", error.localizedDescription)
        }
    }

    nonisolated static func absoluteFilePath(from path: String) -> String? {
        if path.hasPrefix("/") { return path }
        #if os(Windows)
            if path.hasPrefix("\\\\") { return path }
            let prefix = Array(path.utf8.prefix(3))
            guard prefix.count == 3, prefix[1] == 58,
                prefix[2] == 47 || prefix[2] == 92,
                (65...90).contains(prefix[0]) || (97...122).contains(prefix[0]) else { return nil }
            return path
        #else
            return nil
        #endif
    }

    nonisolated static func buildProjectTreeItems(
        at projectURL: URL, fileManager: FileManager, projectMetadata suppliedMetadata: AdaProject? = nil
    ) -> [EditorProjectSidebarViewModel.Item] {
        let projectMetadata = suppliedMetadata ?? (try? ProjectSystem.loadProject(at: projectURL, fileManager: fileManager))
        let assetsRoot = projectMetadata?.paths.assets ?? "Assets"
        let resourceRoots = Array(Set((projectMetadata?.paths.resourceRoots ?? []) + [assetsRoot]))
            .sorted { $0.count > $1.count }
        var items: [EditorProjectSidebarViewModel.Item] = []
        for entry in projectTreeEntries(at: projectURL, fileManager: fileManager) {
            appendProjectTreeItems(
                entry: entry,
                parentPath: "",
                level: 0,
                resourceRoots: resourceRoots,
                fileManager: fileManager,
                items: &items
            )
        }

        if !items.contains(where: \.isActive), let firstSelectableIndex = items.firstIndex(where: { !$0.isFolder }) {
            items[firstSelectableIndex].isActive = true
        }

        return items
    }

    nonisolated private static func appendProjectTreeItems(
        entry: EditorProjectTreeEntry,
        parentPath: String,
        level: Int,
        resourceRoots: [String],
        fileManager: FileManager,
        items: inout [EditorProjectSidebarViewModel.Item]
    ) {
        guard !Task.isCancelled else { return }
        let url = entry.url
        let isDirectory = entry.isDirectory
        let isSymbolicLink = entry.isSymbolicLink
        let relativePath = parentPath.isEmpty ? entry.name : "\(parentPath)/\(entry.name)"
        let kind = fileKind(for: url, isDirectory: isDirectory)
        let itemAssetRoot = resourceRoots.first { root in
            let resourcePrefix = root.hasSuffix("/") ? root : "\(root)/"
            return relativePath == root || relativePath.hasPrefix(resourcePrefix)
        }

        items.append(
            EditorProjectSidebarViewModel.Item(
                id: url.path,
                disclosure: isDirectory ? "▾" : "",
                icon: "▱",
                title: entry.name,
                relativePath: relativePath,
                level: level,
                isActive: false,
                isFolder: isDirectory,
                isSymbolicLink: isSymbolicLink,
                kind: kind,
                assetRoot: itemAssetRoot
            )
        )

        guard isDirectory, !isSymbolicLink else {
            return
        }

        for child in projectTreeEntries(at: url, fileManager: fileManager) {
            appendProjectTreeItems(
                entry: child,
                parentPath: relativePath,
                level: level + 1,
                resourceRoots: resourceRoots,
                fileManager: fileManager,
                items: &items
            )
        }
    }

    nonisolated private static func projectTreeEntries(at directory: URL, fileManager: FileManager) -> [EditorProjectTreeEntry] {
        guard !Task.isCancelled else { return [] }
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []
        )) ?? []
        // On Windows URL resource queries can hit the filesystem even during sorting.
        // Snapshot each entry once instead of issuing two queries per comparison.
        return urls.filter { !shouldSkipProjectTreeURL($0) }.map { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return EditorProjectTreeEntry(url: url, name: url.lastPathComponent,
                                          isDirectory: values?.isDirectory == true, isSymbolicLink: values?.isSymbolicLink == true)
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    nonisolated static func fileKind(for url: URL, isDirectory: Bool) -> EditorProjectFileKind {
        if isDirectory {
            return .folder
        }

        if SceneDocumentFormat.isSceneFile(url) {
            return .scene
        }
        if url.pathExtension.lowercased() == "shadergraph" { return .genericAsset }

        if isImageAsset(url) {
            return .image
        }

        if isAudioAsset(url) {
            return .audio
        }

        if url.pathExtension.lowercased() == "tileset" || EditorModelResource.extensions.contains(url.pathExtension.lowercased()) || EditorSpineResource.extensions.contains(url.pathExtension.lowercased()) {
            return .genericAsset
        }

        if isTextFile(url) {
            return .text(EditorSourceLanguage.detect(fileName: url.lastPathComponent))
        }

        return .genericAsset
    }

    nonisolated static func assetDocument(for item: EditorProjectSidebarViewModel.Item) -> EditorAssetDocument {
        let absolutePath = absoluteFilePath(from: item.id)
        let url = absolutePath.map { URL(fileURLWithPath: $0, isDirectory: false) }
        let values = url.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) }
        let fileExtension = URL(fileURLWithPath: item.title).pathExtension.lowercased()

        return EditorAssetDocument(
            id: "asset:\(item.relativePath)",
            title: item.title,
            relativePath: item.relativePath,
            absolutePath: absolutePath,
            assetReference: item.assetRoot.flatMap { assetReference(for: item.relativePath, assetsRoot: $0) },
            kind: assetPreviewKind(for: item.kind, fileExtension: fileExtension),
            fileExtension: fileExtension,
            byteCount: values?.fileSize.map(Int64.init),
            modifiedAt: values?.contentModificationDate,
            errorMessage: item.kind == .image && item.title.lowercased().hasSuffix(".png") == false ? "Only PNG image decoding is currently available in editor preview." : nil
        )
    }

    nonisolated static func assetPreviewKind(
        for kind: EditorProjectFileKind,
        fileExtension: String
    ) -> EditorAssetPreviewKind {
        if fileExtension == "shadergraph" { return .shaderGraph }
        if EditorSpineResource.extensions.contains(fileExtension.lowercased()) { return .spine2D }
        if EditorModelResource.extensions.contains(fileExtension.lowercased()) {
            return .model3D
        }
        if fileExtension == "tileset" {
            return .tileSource
        }
        if fileExtension == "tilemap" {
            return .tileMap
        }
        if fileExtension == "atlas" {
            return .atlas
        }
        if fileExtension == "particles" {
            return .particleEffect
        }
        if fileExtension == "spriteanim" {
            return .spriteAnimation
        }
        if fileExtension == "animlib" { return .animationLibrary }
        if fileExtension == "animmod" { return .animationModifiers }
        switch kind {
        case .image:
            return .image
        case .audio:
            return .audio
        default:
            return .generic
        }
    }

    nonisolated static func assetReference(for relativePath: String, assetsRoot: String = "Assets") -> String? {
        let prefix = assetsRoot.hasSuffix("/") ? assetsRoot : "\(assetsRoot)/"
        guard relativePath == assetsRoot || relativePath.hasPrefix(prefix) else {
            return nil
        }

        let assetPath = relativePath == assetsRoot ? "" : String(relativePath.dropFirst(prefix.count))
        return "@res://\(assetPath)"
    }

    static func textureAssets(from items: [EditorProjectSidebarViewModel.Item]) -> [EditorInspectorSidebarViewModel.TextureAsset] {
        items.compactMap { item in
            guard
                item.kind == .image,
                let assetsRoot = item.assetRoot,
                let reference = assetReference(for: item.relativePath, assetsRoot: assetsRoot),
                let absolutePath = absoluteFilePath(from: item.id)
            else {
                return nil
            }
            return EditorInspectorSidebarViewModel.TextureAsset(
                name: item.title,
                reference: reference,
                absolutePath: absolutePath
            )
        }
    }

    static func tileMapAssets(from items: [EditorProjectSidebarViewModel.Item]) -> [EditorInspectorSidebarViewModel.TextureAsset] {
        items.compactMap { item in
            guard URL(fileURLWithPath: item.title).pathExtension.lowercased() == "tilemap",
                let assetsRoot = item.assetRoot,
                let reference = assetReference(for: item.relativePath, assetsRoot: assetsRoot),
                let absolutePath = absoluteFilePath(from: item.id) else { return nil }
            return .init(name: item.title, reference: reference, absolutePath: absolutePath)
        }
    }

    static func spriteAnimationAssets(from items: [EditorProjectSidebarViewModel.Item]) -> [EditorInspectorSidebarViewModel.TextureAsset] {
        items.compactMap { item in
            guard URL(fileURLWithPath: item.title).pathExtension.lowercased() == "spriteanim",
                let root = item.assetRoot, let reference = assetReference(for: item.relativePath, assetsRoot: root),
                let absolute = absoluteFilePath(from: item.id) else { return nil }
            return .init(name: item.title, reference: reference, absolutePath: absolute)
        }
    }

    static func particleEffectAssets(from items: [EditorProjectSidebarViewModel.Item]) -> [EditorInspectorSidebarViewModel.TextureAsset] {
        items.compactMap { item in
            guard URL(fileURLWithPath: item.title).pathExtension.lowercased() == "particles",
                let root = item.assetRoot, let reference = assetReference(for: item.relativePath, assetsRoot: root),
                let absolute = absoluteFilePath(from: item.id) else { return nil }
            return .init(name: item.title, reference: reference, absolutePath: absolute)
        }
    }

    static func sceneAssets(from items: [EditorProjectSidebarViewModel.Item]) -> [EditorInspectorSidebarViewModel.SceneAsset] {
        items.compactMap { item in
            guard
                item.kind == .scene,
                let assetsRoot = item.assetRoot,
                let reference = assetReference(for: item.relativePath, assetsRoot: assetsRoot),
                let absolutePath = absoluteFilePath(from: item.id)
            else {
                return nil
            }
            return EditorInspectorSidebarViewModel.SceneAsset(
                name: item.title,
                reference: reference,
                absolutePath: absolutePath
            )
        }
    }

    static func modelAssets(from items: [EditorProjectSidebarViewModel.Item]) -> [EditorInspectorSidebarViewModel.TextureAsset] {
        items.compactMap { item in
            guard !item.isFolder, EditorModelResource.extensions.contains(URL(fileURLWithPath: item.title).pathExtension.lowercased()),
                let assetsRoot = item.assetRoot,
                let reference = assetReference(for: item.relativePath, assetsRoot: assetsRoot),
                let absolutePath = absoluteFilePath(from: item.id) else { return nil }
            return .init(name: item.title, reference: reference, absolutePath: absolutePath)
        }
    }

    static func uiSourcePaths(from items: [EditorProjectSidebarViewModel.Item]) -> [String] {
        items.compactMap { item in
            let ext = URL(fileURLWithPath: item.title).pathExtension.lowercased()
            guard ["ui", "ada"].contains(ext) else {
                return nil
            }
            if ext == "ui", let root = item.assetRoot {
                return assetReference(for: item.relativePath, assetsRoot: root)
            }
            return item.relativePath
        }
        .sorted()
    }

    static func uiSceneFiles(from items: [EditorProjectSidebarViewModel.Item]) -> [String: String] {
        var files: [String: String] = [:]
        for item in items where URL(fileURLWithPath: item.title).pathExtension.lowercased() == "ui" {
            guard let absolutePath = absoluteFilePath(from: item.id) else {
                continue
            }
            let reference = item.assetRoot.flatMap { assetReference(for: item.relativePath, assetsRoot: $0) } ?? item.relativePath
            files[reference] = absolutePath
        }
        return files
    }

    func syncInspectorTextureAssets() {
        inspectorSidebar.textureAssets = Self.textureAssets(from: projectSidebar.items)
        inspectorSidebar.tileMapAssets = Self.tileMapAssets(from: projectSidebar.items)
        inspectorSidebar.particleEffectAssets = Self.particleEffectAssets(from: projectSidebar.items)
        inspectorSidebar.spriteAnimationAssets = Self.spriteAnimationAssets(from: projectSidebar.items)
        inspectorSidebar.modelAssets = Self.modelAssets(from: projectSidebar.items)
        inspectorSidebar.shaderGraphAssets = Self.shaderGraphAssets(from: projectSidebar.items)
        inspectorSidebar.spineAssets = projectSidebar.items.compactMap { item in
            guard !item.isFolder, EditorSpineResource.extensions.contains(URL(fileURLWithPath: item.title).pathExtension.lowercased()),
                  let root = item.assetRoot, let reference = Self.assetReference(for: item.relativePath, assetsRoot: root),
                  let path = Self.absoluteFilePath(from: item.id) else { return nil }
            return .init(name: item.title, reference: reference, absolutePath: path)
        }
        inspectorSidebar.sceneAssets = Self.sceneAssets(from: projectSidebar.items)
        inspectorSidebar.uiSourcePaths = Self.uiSourcePaths(from: projectSidebar.items)
        inspectorSidebar.uiSceneFiles = Self.uiSceneFiles(from: projectSidebar.items)
    }

    static func assetsDirectoryURL(for projectURL: URL, fileManager: FileManager) -> URL {
        let projectMetadata = try? ProjectSystem.loadProject(at: projectURL, fileManager: fileManager)
        return projectURL.appendingPathComponent(projectMetadata?.paths.assets ?? "Assets", isDirectory: true)
    }

    nonisolated static func isImageAsset(_ url: URL) -> Bool {
        Image.extensions().contains(url.pathExtension.lowercased())
    }

    nonisolated static func isAudioAsset(_ url: URL) -> Bool {
        ["wav", "mp3", "ogg", "flac", "m4a"].contains(url.pathExtension.lowercased())
    }

    nonisolated static func isTextFile(_ url: URL) -> Bool {
        let lowercasedName = url.lastPathComponent.lowercased()

        return lowercasedName == "package.swift"
            || lowercasedName == "readme"
            || editorProjectTextExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated static func relativePath(for url: URL, projectURL: URL) -> String {
        let projectPath = projectURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path

        guard path.hasPrefix(projectPath) else {
            return url.lastPathComponent
        }

        let startIndex = path.index(path.startIndex, offsetBy: projectPath.count)
        return String(path[startIndex...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    nonisolated static func shouldSkipProjectTreeURL(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return editorProjectSkippedNames.contains(name) || name == ".build" || name.hasPrefix(".build-")
    }

    nonisolated static func isSymbolicLink(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}

extension EditorRunDestination {
    var adaProjectDestination: AdaProjectRunDestination {
        switch self {
        case .macOS: .macOS
        case .windows: .windows
        case .linux: .linux
        case .visionOS: .visionOS
        case .iPadOS,
            .player:
            .iPadOS
        case .web: .web
        case .android: .android
        }
    }
}
