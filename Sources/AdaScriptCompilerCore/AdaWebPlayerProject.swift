import Foundation

/// Portable input for the source-backed Web Player prototype. All paths are relative to the project directory.
/// Version 1 supports AdaScript views; ECS systems, editor scene files and custom native types are not supported.
public struct AdaWebPlayerProject: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var runtimeAPI: Int
    public var title: String
    public var entryView: String
    public var startupSystem: String?
    public var sources: [String]
    public var assets: [AdaWebPlayerAsset]?
    public var materials: [AdaWebPlayerMaterial]?

    public init(title: String, entryView: String, startupSystem: String? = nil, sources: [String]) {
        self.schemaVersion = 1
        self.runtimeAPI = 1
        self.title = title
        self.entryView = entryView
        self.startupSystem = startupSystem
        self.sources = sources
    }

    public func validate() throws {
        guard schemaVersion == 1, (1...2).contains(runtimeAPI) else {
            throw AdaWebPlayerProjectError.invalid("Unsupported Web Player schema or runtime API; expected API 1 or 2.")
        }
        try validateResources()
        guard
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !entryView.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AdaWebPlayerProjectError.invalid("Web Player requires a title and an entry view.")
        }
        guard !sources.isEmpty, Set(sources.map { $0.lowercased() }).count == sources.count else {
            throw AdaWebPlayerProjectError.invalid("Web Player requires unique AdaScript source paths.")
        }
        guard startupSystem == nil else {
            throw AdaWebPlayerProjectError.invalid("This Web Player profile supports AdaScript views; ECS systems require the scene profile.")
        }
        for path in sources {
            guard AdaScriptLibraryManifest.isSourcePath(path) else {
                throw AdaWebPlayerProjectError.invalid("Invalid Web Player source path: \(path).")
            }
        }
    }

    public static func load(at directory: URL) throws -> Self {
        let project = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("project.json")))
        try project.validate()
        return project
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

public enum AdaWebPlayerProjectError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case let .invalid(message): message
        }
    }
}
