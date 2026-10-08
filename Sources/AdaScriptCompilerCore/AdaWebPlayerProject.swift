import Foundation

/// Portable input for the source-backed Web Player. All paths are relative to the project directory.
public struct AdaWebPlayerProject: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var runtimeAPI: Int
    public var title: String
    public var entryView: String
    public var entryScene: String?
    public var moduleName: String?
    public var startupSystem: String?
    public var sources: [String]
    /// Scene and runtime metadata files loaded from the Web Player's virtual filesystem.
    public var files: [String]?
    public var assets: [AdaWebPlayerAsset]?
    public var materials: [AdaWebPlayerMaterial]?

    public init(title: String, entryView: String, startupSystem: String? = nil, sources: [String]) {
        self.schemaVersion = 1
        self.runtimeAPI = 1
        self.title = title
        self.entryView = entryView
        self.entryScene = nil
        self.moduleName = nil
        self.startupSystem = startupSystem
        self.sources = sources
    }

    /// Creates a scene-backed project whose systems and scene load in the Web Player.
    public init(title: String, entryScene: String, moduleName: String, startupSystem: String? = nil, sources: [String]) {
        self.schemaVersion = 1
        self.runtimeAPI = 3
        self.title = title
        self.entryView = ""
        self.entryScene = entryScene
        self.moduleName = moduleName
        self.startupSystem = startupSystem
        self.sources = sources
    }

    public var profile: String { entryScene == nil ? "views" : "scene" }

    public func validate() throws {
        guard schemaVersion == 1, (1...3).contains(runtimeAPI) else {
            throw AdaWebPlayerProjectError.invalid("Unsupported Web Player schema or runtime API; expected API 1, 2 or 3.")
        }
        try validateResources()
        guard
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AdaWebPlayerProjectError.invalid("Web Player requires a title.")
        }
        if let entryScene {
            guard runtimeAPI >= 3, Self.isProjectPath(entryScene),
                moduleName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                files?.contains(entryScene) == true
            else {
                throw AdaWebPlayerProjectError.invalid("Scene projects require API 3, a safe scene path and a module name.")
            }
        } else {
            guard !entryView.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AdaWebPlayerProjectError.invalid("Web Player requires an entry view.")
            }
            guard startupSystem == nil else {
                throw AdaWebPlayerProjectError.invalid("This Web Player profile supports AdaScript views; ECS systems require the scene profile.")
            }
        }
        guard !sources.isEmpty, Set(sources.map { $0.lowercased() }).count == sources.count else {
            throw AdaWebPlayerProjectError.invalid("Web Player requires unique AdaScript source paths.")
        }
        for path in sources {
            guard AdaScriptLibraryManifest.isSourcePath(path) else {
                throw AdaWebPlayerProjectError.invalid("Invalid Web Player source path: \(path).")
            }
        }
        for path in files ?? [] {
            guard Self.isProjectPath(path) else {
                throw AdaWebPlayerProjectError.invalid("Invalid Web Player file path: \(path).")
            }
        }
    }

    private static func isProjectPath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\\") && !path.contains(":")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    public static func load(at directory: URL) throws -> Self {
        let webManifest = directory.appendingPathComponent("project.json")
        let project: Self
        if FileManager.default.fileExists(atPath: webManifest.path) {
            project = try JSONDecoder().decode(Self.self, from: Data(contentsOf: webManifest))
        } else {
            project = try loadAdaProject(at: directory)
        }
        try project.validate()
        return project
    }

    /// Adapts a portable `.ada/project.json` scene project for the generic Web Player.
    public static func loadAdaProject(at directory: URL) throws -> Self {
        let metadata = try JSONDecoder().decode(
            AdaProjectMetadata.self,
            from: Data(contentsOf: directory.appendingPathComponent(".ada/project.json"))
        )
        guard metadata.build.system == "adascript" else {
            throw AdaWebPlayerProjectError.invalid("Web Player requires an AdaScript project.")
        }
        let sourceRoot = metadata.paths.sources ?? "Sources"
        let assetRoot = metadata.paths.assets ?? "Assets"
        guard Self.isProjectPath(sourceRoot), Self.isProjectPath(assetRoot) else {
            throw AdaWebPlayerProjectError.invalid("Invalid AdaScript project source or asset root.")
        }
        let sources = try regularFiles(under: sourceRoot, in: directory).filter { $0.hasSuffix(".ada") }
        let assets = try regularFiles(under: assetRoot, in: directory)
        let title = metadata.project.displayName ?? metadata.project.name ?? "AdaScript Game"
        let moduleName = metadata.runtime.moduleName ?? metadata.project.name ?? "AdaScriptGame"
        let project: Self
        if let scene = metadata.runtime.entry.scene {
            project = Self(
                title: title,
                entryScene: scene,
                moduleName: moduleName,
                startupSystem: metadata.runtime.entry.startupSystem,
                sources: sources
            )
        } else if let view = metadata.runtime.entry.view {
            project = Self(title: title, entryView: view, sources: sources)
        } else {
            throw AdaWebPlayerProjectError.invalid("AdaScript Web project requires an entry scene or view.")
        }
        var result = project
        result.files = assets
        try result.validate()
        return result
    }

    private static func regularFiles(under root: String, in directory: URL) throws -> [String] {
        let projectRoot = directory.resolvingSymlinksInPath().standardizedFileURL
        let rootURL = projectRoot.appendingPathComponent(root, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var paths: [String] = []
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let resolved = file.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(projectRoot.path + "/") else {
                throw AdaWebPlayerProjectError.invalid("Project file escapes its root: \(file.path)")
            }
            let relative = String(resolved.dropFirst(projectRoot.path.count + 1))
            guard isProjectPath(relative) else {
                throw AdaWebPlayerProjectError.invalid("Invalid AdaScript project file path: \(relative)")
            }
            paths.append(relative)
        }
        return paths.sorted()
    }

    /// Reads source bytes at launch, so replacing game content never requires relinking the player.
    public func loadSources(at directory: URL) throws -> [AdaScriptCompilerSource] {
        try validate()
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        return try sources.map { path in
            let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") else {
                throw AdaWebPlayerProjectError.invalid("Source escapes the Web Player project: \(path).")
            }
            return try AdaScriptCompilerSource(path: path, source: String(contentsOf: url, encoding: .utf8))
        }
    }
}

private struct AdaProjectMetadata: Decodable {
    struct Build: Decodable { let system: String }
    struct Details: Decodable { let displayName: String?; let name: String? }
    struct Entry: Decodable { let scene: String?; let startupSystem: String?; let view: String? }
    struct Paths: Decodable { let assets: String?; let sources: String? }
    struct Runtime: Decodable { let entry: Entry; let moduleName: String? }

    let build: Build
    let paths: Paths
    let project: Details
    let runtime: Runtime
}

public enum AdaWebPlayerProjectError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case let .invalid(message): message
        }
    }
}
