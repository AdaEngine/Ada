import Foundation

public struct AdaScriptLockedLibrary: Codable, Equatable, Sendable {
    public var manifest: AdaScriptLibraryManifest
    public var source: AdaScriptLibrarySource
    /// Immutable installation directory, relative to .ada/libraries.
    public var directory: String

    public init(manifest: AdaScriptLibraryManifest, source: AdaScriptLibrarySource, directory: String) {
        self.manifest = manifest
        self.source = source
        self.directory = directory
    }
}

/// Commit this lock and .ada/libraries to share an offline, reproducible project.
public struct AdaScriptLibraryLock: Codable, Equatable, Sendable {
    public static let relativePath = ".ada/libraries.lock.json"
    public var schemaVersion: Int = 1
    public var roots: [String]
    public var libraries: [AdaScriptLockedLibrary]

    public init(roots: [String] = [], libraries: [AdaScriptLockedLibrary] = []) {
        self.roots = roots
        self.libraries = libraries
    }

    public static func load(at projectURL: URL) throws -> Self {
        let url = try containedURL(relativePath, in: projectURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Self()
        }
        let lock = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        _ = try lock.orderedLibraries()
        return lock
    }

    /// Checks the complete graph and returns dependencies before their consumers.
    public func orderedLibraries() throws -> [AdaScriptLockedLibrary] {
        guard
            schemaVersion == 1, libraries.count <= 128,
            Set(libraries.map(\.manifest.id)).count == libraries.count,
            Set(roots).count == roots.count
        else {
            throw AdaScriptLibraryError.invalid("Invalid AdaScript library lock.")
        }
        for library in libraries {
            try library.manifest.validate()
            guard UUID(uuidString: library.directory) != nil else {
                throw AdaScriptLibraryError.invalid("Invalid installation directory for \(library.manifest.id).")
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: libraries.map { ($0.manifest.id, $0) })
        var visiting: Set<String> = []
        var visited: Set<String> = []
        var ordered: [AdaScriptLockedLibrary] = []
        func visit(_ id: String) throws {
            guard !visiting.contains(id) else {
                throw AdaScriptLibraryError.invalid("AdaScript library dependency cycle at \(id).")
            }
            guard !visited.contains(id) else {
                return
            }
            guard let library = byID[id] else {
                throw AdaScriptLibraryError.invalid("Missing AdaScript library \(id). Install or restore libraries in Project Settings.")
            }
            visiting.insert(id)
            for dependency in library.manifest.dependencies.sorted(by: { $0.id < $1.id }) {
                guard byID[dependency.id]?.source == dependency.source else {
                    throw AdaScriptLibraryError.invalid("Conflicting or missing revision for \(dependency.id), required by \(id).")
                }
                try visit(dependency.id)
            }
            visiting.remove(id)
            visited.insert(id)
            ordered.append(library)
        }
        for id in roots.sorted() { try visit(id) }
        return ordered
    }

    public func loadSources(at projectURL: URL) throws -> [AdaScriptCompilerSource] {
        try orderedLibraries()
            .flatMap { library in
                try library.manifest.sources.sorted()
                    .map { path in
                        let relativePath = ".ada/libraries/\(library.directory)/\(path)"
                        let url = try Self.containedURL(relativePath, in: projectURL)
                        guard FileManager.default.fileExists(atPath: url.path) else {
                            throw AdaScriptLibraryError.invalid("Missing \(library.manifest.id)/\(path). Restore libraries in Project Settings.")
                        }
                        return try AdaScriptCompilerSource(
                            path: "Libraries/\(library.manifest.id)/\(path)",
                            source: String(contentsOf: url, encoding: .utf8)
                        )
                    }
            }
    }

    /// Library files and their parent directories must not be symbolic links.
    public static func containedURL(_ path: String, in root: URL) throws -> URL {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard
            !components.isEmpty, !path.contains("\\"),
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw AdaScriptLibraryError.invalid("Library path escapes the project: \(path).")
        }
        var url = resolvedRoot
        // Resolve each existing parent: resolvingSymlinksInPath alone can miss links when the leaf does not exist yet.
        for component in components {
            url.appendPathComponent(String(component))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                throw AdaScriptLibraryError.invalid("Symbolic links are not allowed in library paths: \(path).")
            }
        }
        return url
    }
}
