@_spi(AdaEngine) import AdaEngine
import AdaPackageManifestTool
import Foundation
import Observation

extension EditorViewModel {
    static func projectTreeItems(for project: EditorProjectReference?, fileManager: FileManager) -> [EditorProjectSidebarViewModel.Item] {
        guard let project else {
            return EditorProjectSidebarViewModel().items
        }

        let projectURL = URL(fileURLWithPath: project.path, isDirectory: true)
        return buildProjectTreeItems(at: projectURL, fileManager: fileManager)
    }

    static func document(for item: EditorProjectSidebarViewModel.Item) -> EditorWorkbenchDocument {
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
            let sceneModel = EditorSceneFileLoader.model(from: content.value)
            return .scene(
                EditorSceneDocument(
                    id: "scene:\(item.relativePath)",
                    title: item.title,
                    relativePath: item.relativePath,
                    absolutePath: absoluteFilePath(from: item.id),
                    content: content.value,
                    lastSavedContent: content.errorMessage == nil ? content.value : nil,
                    isReadOnly: item.isSymbolicLink,
                    sceneModel: sceneModel,
                    errorMessage: content.errorMessage,
                    isDirty: false,
                    statusMessage: item.isSymbolicLink ? "Read-only: symbolic link" : content.errorMessage == nil ? "Loaded" : nil,
                    loadSummary: EditorSceneFileLoader.summary(from: content.value)
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

    static func textFileContent(for item: EditorProjectSidebarViewModel.Item) -> (value: String, errorMessage: String?) {
        guard let absolutePath = absoluteFilePath(from: item.id) else {
            return (AdaEngineStyleContent.sampleTextDocuments[item.relativePath] ?? "", nil)
        }

        do {
            return (try String(contentsOf: URL(fileURLWithPath: absolutePath, isDirectory: false), encoding: .utf8), nil)
        } catch {
            return ("", error.localizedDescription)
        }
    }

    static func sceneFileContent(for item: EditorProjectSidebarViewModel.Item) -> (value: String, errorMessage: String?) {
        guard let absolutePath = absoluteFilePath(from: item.id) else {
            return (SceneDocumentFormat.defaultSceneYAML(projectName: item.title), nil)
        }

        do {
            return (try String(contentsOf: URL(fileURLWithPath: absolutePath), encoding: .utf8), nil)
        } catch {
            return ("", error.localizedDescription)
        }
    }

    static func absoluteFilePath(from path: String) -> String? {
        path.hasPrefix("/") ? path : nil
    }

    static func buildProjectTreeItems(at projectURL: URL, fileManager: FileManager) -> [EditorProjectSidebarViewModel.Item] {
        let projectMetadata = try? ProjectSystem.loadProject(at: projectURL, fileManager: fileManager)
        let assetsRoot = projectMetadata?.paths.assets ?? "Assets"
        let resourceRoots = Array(Set((projectMetadata?.paths.resourceRoots ?? []) + [assetsRoot]))
            .sorted { $0.count > $1.count }
        var items: [EditorProjectSidebarViewModel.Item] = []
        let rootEntries =
            (try? fileManager.contentsOfDirectory(
                at: projectURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )) ?? []

        for url in rootEntries.sorted(by: projectTreeSort) where !shouldSkipProjectTreeURL(url) {
            appendProjectTreeItems(
                url: url,
                projectURL: projectURL,
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

    static func appendProjectTreeItems(
        url: URL,
        projectURL: URL,
        level: Int,
        resourceRoots: [String],
        fileManager: FileManager,
        items: inout [EditorProjectSidebarViewModel.Item]
    ) {
        guard items.count < 2_000 else {
            return
        }

        let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let isDirectory = resourceValues?.isDirectory == true
        let isSymbolicLink = resourceValues?.isSymbolicLink == true
        let relativePath = relativePath(for: url, projectURL: projectURL)
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
                title: url.lastPathComponent,
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

        let childURLs =
            (try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )) ?? []

        for childURL in childURLs.sorted(by: projectTreeSort) where !shouldSkipProjectTreeURL(childURL) {
            appendProjectTreeItems(
                url: childURL,
                projectURL: projectURL,
                level: level + 1,
                resourceRoots: resourceRoots,
                fileManager: fileManager,
                items: &items
            )
        }
    }

    static func fileKind(for url: URL, isDirectory: Bool) -> EditorProjectFileKind {
        if isDirectory {
            return .folder
        }

        if SceneDocumentFormat.isSceneFile(url) {
            return .scene
        }

        if isImageAsset(url) {
            return .image
        }

        if isAudioAsset(url) {
            return .audio
        }

        if url.pathExtension.lowercased() == "tileset" {
            return .genericAsset
        }

        if isTextFile(url) {
            return .text(EditorSourceLanguage.detect(fileName: url.lastPathComponent))
        }

        return .genericAsset
    }

    static func assetDocument(for item: EditorProjectSidebarViewModel.Item) -> EditorAssetDocument {
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

    static func assetPreviewKind(
        for kind: EditorProjectFileKind,
        fileExtension: String
    ) -> EditorAssetPreviewKind {
        if fileExtension == "tileset" {
            return .tileSource
        }
        if fileExtension == "atlas" {
            return .atlas
        }
        switch kind {
        case .image:
            return .image
        case .audio:
            return .audio
        default:
            return .generic
        }
    }

    static func assetReference(for relativePath: String, assetsRoot: String = "Assets") -> String? {
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
        inspectorSidebar.sceneAssets = Self.sceneAssets(from: projectSidebar.items)
        inspectorSidebar.uiSourcePaths = Self.uiSourcePaths(from: projectSidebar.items)
        inspectorSidebar.uiSceneFiles = Self.uiSceneFiles(from: projectSidebar.items)
    }

    static func assetsDirectoryURL(for projectURL: URL, fileManager: FileManager) -> URL {
        let projectMetadata = try? ProjectSystem.loadProject(at: projectURL, fileManager: fileManager)
        return projectURL.appendingPathComponent(projectMetadata?.paths.assets ?? "Assets", isDirectory: true)
    }

    static func isImageAsset(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp"].contains(url.pathExtension.lowercased())
    }

    static func isAudioAsset(_ url: URL) -> Bool {
        ["wav", "mp3", "ogg", "flac", "m4a"].contains(url.pathExtension.lowercased())
    }

    static func isTextFile(_ url: URL) -> Bool {
        let textExtensions: Set<String> = [
            "ada", "c", "cc", "comp", "cpp", "cxx", "frag", "geom", "glsl", "gravity", "h", "hpp", "hxx", "json", "md", "markdown",
            "ui", "ascn", "tileset", "metal", "plist", "scn", "scene", "shader", "strings", "swift", "tesc", "tese", "toml", "txt", "vert", "wgsl", "xml", "yaml", "yml",
        ]
        let lowercasedName = url.lastPathComponent.lowercased()

        return lowercasedName == "package.swift"
            || lowercasedName == "readme"
            || textExtensions.contains(url.pathExtension.lowercased())
    }

    static func relativePath(for url: URL, projectURL: URL) -> String {
        let projectPath = projectURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path

        guard path.hasPrefix(projectPath) else {
            return url.lastPathComponent
        }

        let startIndex = path.index(path.startIndex, offsetBy: projectPath.count)
        return String(path[startIndex...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func projectTreeSort(lhs: URL, rhs: URL) -> Bool {
        let lhsIsDirectory = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let rhsIsDirectory = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true

        if lhsIsDirectory != rhsIsDirectory {
            return lhsIsDirectory
        }

        return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }

    static func shouldSkipProjectTreeURL(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let skippedNames: Set<String> = [".ada", ".DS_Store", ".git", ".swiftpm", "DerivedData"]
        return skippedNames.contains(name) || name == ".build" || name.hasPrefix(".build-")
    }

    static func isSymbolicLink(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}

extension EditorRunDestination {
    var adaProjectDestination: AdaProjectRunDestination {
        switch self {
        case .macOS: .macOS
        case .iPadOS,
            .player:
            .iPadOS
        case .web: .web
        }
    }
}
