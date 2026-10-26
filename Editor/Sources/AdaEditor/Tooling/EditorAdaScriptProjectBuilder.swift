import AdaEngine
import AdaScriptCompilerCore
import Foundation

struct EditorAdaScriptProjectBuildReport: Equatable, Sendable {
    let entryDescription: String
    let entryView: String?
    let moduleName: String
    let pluginIDs: [String]
    let sourceCount: Int
    let startupScene: String?
    let startupSystem: String?
    let systemCount: Int
    let viewCount: Int
}

struct EditorAdaScriptProjectBuildArtifact: Sendable {
    let assetsDirectory: URL
    let storageIdentifier: String?
    let entry: AdaProjectRuntimeEntry
    let moduleName: String
    let plugins: EditorAdaScriptResolvedRuntimePlugins
    let report: EditorAdaScriptProjectBuildReport
    let sceneModel: EditorSceneModel?
    let scenePlayRuntime: EditorScenePlayRuntime
    let sources: [AdaScriptSource]
    let window: AdaProjectRuntimeWindow

    func assetDirectories() throws -> ProjectDirectories {
        let source = assetsDirectory.deletingLastPathComponent()
        if let storageIdentifier {
            return try ProjectDirectories(source: source, assetsDirectory: assetsDirectory, storageIdentifier: storageIdentifier)
        }
        return ProjectDirectories(source: source, assetsDirectory: assetsDirectory)
    }
}

enum EditorAdaScriptProjectBuildError: Error, Equatable, LocalizedError, Sendable {
    case entryViewMissing(identifier: String)
    case uiViewsUnavailable
    case noSources(path: String)
    case notAdaScriptProject(buildSystem: String)
    case sourceReadFailed(path: String, message: String)
    case startupSceneInvalid(path: String, message: String)
    case startupSceneMissing(path: String)
    case typeChecking(String)

    var errorDescription: String? {
        switch self {
        case let .entryViewMissing(identifier):
            "AdaScript entry view '\(identifier)' is temporarily unavailable. Remove runtime.entry.view."
        case .uiViewsUnavailable:
            "AdaUI views in AdaScript are temporarily unavailable. Remove runtime.entry.view and @view declarations."
        case let .noSources(path):
            "No .ada source files were found under \(path)."
        case let .notAdaScriptProject(buildSystem):
            "Expected an AdaScript project, but build.system is '\(buildSystem)'."
        case let .sourceReadFailed(path, message):
            "Failed to read \(path): \(message)"
        case let .startupSceneInvalid(path, message):
            "AdaScript startup scene '\(path)' is invalid: \(message)"
        case let .startupSceneMissing(path):
            "AdaScript startup scene was not found at \(path)."
        case let .typeChecking(message):
            message
        }
    }
}

/// Builds a portable AdaScript project directly in the editor process without invoking SwiftPM.
struct EditorAdaScriptProjectBuilder {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func build(project: AdaProject, at projectURL: URL) throws -> EditorAdaScriptProjectBuildReport {
        try prepare(project: project, at: projectURL).report
    }

    func prepare(
        project: AdaProject,
        at projectURL: URL,
        sourceOverrides: [String: String] = [:],
        validatesRuntime: Bool = true
    ) throws -> EditorAdaScriptProjectBuildArtifact {
        guard project.build.system.isAdaScript else {
            throw EditorAdaScriptProjectBuildError.notAdaScriptProject(buildSystem: project.build.system.rawValue)
        }
        guard project.runtime.entry.view == nil else {
            throw EditorAdaScriptProjectBuildError.uiViewsUnavailable
        }
        let storageIdentifier = try EditorProjectStorageIdentity.resolve(project)

        let sourceRoot = project.paths.sources ?? "Sources"
        let sources =
            try loadSources(at: projectURL.appendingPathComponent(sourceRoot, isDirectory: true), toolsRoot: projectURL.appendingPathComponent("Tools"))
                .map { source in
                    let projectPath = sourceRoot + "/" + source.path
                    return AdaScriptSource(path: source.path, source: sourceOverrides[projectPath] ?? source.source)
                }
            + AdaScriptLibraryLock.load(at: projectURL).loadSources(at: projectURL)
        guard !sources.isEmpty else {
            throw EditorAdaScriptProjectBuildError.noSources(path: sourceRoot)
        }

        let dataSchemas = try AdaScriptSchemaParser.parse(sources: sources)
        var analysisEnvironment = AdaScriptTypeEnvironment.standard
        analysisEnvironment.register(schemas: dataSchemas)
        let analysis = AdaScriptAnalyzer.analyze(sources: sources, environment: analysisEnvironment)
        do {
            try analysis.requireValidTypes(mode: project.build.adaScriptTypeChecking)
        } catch let error as AdaScriptTypeCheckingError {
            throw EditorAdaScriptProjectBuildError.typeChecking(error.description)
        }
        let scriptableObjectSupport = try EditorScriptableObjectCatalogLoader.makeResult(
            project: project,
            sources: sources
        )

        let preparedEntry = try prepareEntry(
            project: project,
            sources: sources,
            projectURL: projectURL,
            validatesRuntime: validatesRuntime
        )
        let plugins = try EditorAdaScriptRuntimePluginResolver.resolve(project.runtime.plugins)
        let entryDescription = [
            preparedEntry.entry.scene.map { "scene \($0)" },
            preparedEntry.entry.view.map { "view \($0)" },
            preparedEntry.entry.startupSystem.map { "startup \($0)" },
        ]
        .compactMap { $0 }.joined(separator: ", ")

        let report = EditorAdaScriptProjectBuildReport(
            entryDescription: entryDescription,
            entryView: preparedEntry.entry.view,
            moduleName: project.runtime.moduleName,
            pluginIDs: plugins.pluginIDs.map(\.rawValue),
            sourceCount: sources.count,
            startupScene: preparedEntry.entry.scene,
            startupSystem: preparedEntry.entry.startupSystem,
            systemCount: preparedEntry.systemCount,
            viewCount: preparedEntry.viewCount
        )
        let assetsPath = project.paths.assets ?? "Assets"
        return EditorAdaScriptProjectBuildArtifact(
            assetsDirectory: projectURL.appendingPathComponent(assetsPath, isDirectory: true),
            storageIdentifier: storageIdentifier,
            entry: preparedEntry.entry,
            moduleName: project.runtime.moduleName,
            plugins: plugins,
            report: report,
            sceneModel: preparedEntry.sceneModel,
            scenePlayRuntime: scriptableObjectSupport.playRuntime,
            sources: sources,
            window: project.runtime.window
        )
    }

    private func prepareEntry(
        project: AdaProject,
        sources: [AdaScriptSource],
        projectURL: URL,
        validatesRuntime: Bool
    ) throws -> PreparedAdaScriptRuntimeEntry {
        let entry = AdaProjectRuntimeEntry(
            scene: project.runtime.entry.scene?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            startupSystem: project.runtime.entry.startupSystem?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            view: project.runtime.entry.view?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        let views = try AdaScriptViewScanner.declarations(in: sources)
        if let entryView = entry.view {
            guard views.contains(where: { $0.identifier == entryView }) else {
                throw EditorAdaScriptProjectBuildError.entryViewMissing(identifier: entryView)
            }
            try AdaScriptView.validate(sources: sources, identifier: entryView)
        }

        let systems = try AdaScriptSchemaParser.parseSystemCapabilities(sources: sources)
        if validatesRuntime && (!systems.isEmpty || entry.startupSystem != nil) {
            try AdaScriptPlugin.validate(
                sources: sources,
                name: project.runtime.moduleName,
                startupSystemIdentifier: entry.startupSystem
            )
        }
        return try PreparedAdaScriptRuntimeEntry(
            entry: entry,
            sceneModel: loadStartupScene(entry.scene, at: projectURL),
            systemCount: systems.count,
            viewCount: views.count
        )
    }

    private func loadStartupScene(_ path: String?, at projectURL: URL) throws -> EditorSceneModel? {
        guard let path else {
            return nil
        }
        let sceneURL = projectURL.appendingPathComponent(path, isDirectory: false)
        guard fileManager.fileExists(atPath: sceneURL.path) else {
            throw EditorAdaScriptProjectBuildError.startupSceneMissing(path: path)
        }
        do {
            return try EditorSceneModel.decode(from: String(contentsOf: sceneURL, encoding: .utf8))
        } catch {
            throw EditorAdaScriptProjectBuildError.startupSceneInvalid(
                path: path,
                message: error.localizedDescription
            )
        }
    }

    private func loadSources(at sourceRoot: URL, toolsRoot: URL) throws -> [AdaScriptSource] {
        let sourceRoot = sourceRoot.standardizedFileURL
        guard
            let enumerator = fileManager.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var sources: [AdaScriptSource] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "ada" {
            let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            let toolsPath = toolsRoot.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard !resolved.starts(with: toolsPath) else { continue }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                continue
            }
            let relativePath = relativePath(from: sourceRoot, to: fileURL)
            do {
                sources.append(
                    AdaScriptSource(
                        path: relativePath,
                        source: try String(contentsOf: fileURL, encoding: .utf8)
                    )
                )
            } catch {
                throw EditorAdaScriptProjectBuildError.sourceReadFailed(
                    path: relativePath,
                    message: error.localizedDescription
                )
            }
        }
        return sources.sorted { $0.path < $1.path }
    }

    private func relativePath(from root: URL, to file: URL) -> String {
        let rootPath = root.standardizedFileURL.pathComponents
        let filePath = file.standardizedFileURL.pathComponents
        guard filePath.starts(with: rootPath) else {
            return file.lastPathComponent
        }
        return filePath.dropFirst(rootPath.count).joined(separator: "/")
    }
}

enum EditorProjectStorageIdentity {
    static func resolve(_ project: AdaProject, nativeFallback: Bool = false) throws -> String? {
        for explicit in [project.project.bundleIdentifier, project.project.id].compactMap({ $0 }) {
            try ProjectDirectories.validateStorageIdentifier(explicit)
        }
        if let identifier = project.project.bundleIdentifier ?? project.project.id { return identifier }
        guard nativeFallback, let name = project.project.name, !name.isEmpty else { return nil }
        if (try? ProjectDirectories.validateStorageIdentifier(name)) != nil { return name }
        // Legacy display names may contain spaces or slashes; do not turn them into path components.
        var hash: UInt64 = 14695981039346656037
        for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return "project-" + String(hash, radix: 16)
    }
}

private struct PreparedAdaScriptRuntimeEntry {
    let entry: AdaProjectRuntimeEntry
    let sceneModel: EditorSceneModel?
    let systemCount: Int
    let viewCount: Int
}
