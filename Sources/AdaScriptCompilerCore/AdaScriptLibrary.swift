import Foundation

/// A provider-specific immutable release reference. GitHub uses owner/repository and a commit SHA.
public struct AdaScriptLibrarySource: Codable, Equatable, Hashable, Sendable {
    public var provider: String
    public var location: String
    public var revision: String

    public init(provider: String, location: String, revision: String) {
        self.provider = provider
        self.location = location
        self.revision = revision
    }
}

public struct AdaScriptLibraryDependency: Codable, Equatable, Sendable {
    public var id: String
    public var source: AdaScriptLibrarySource

    public init(id: String, source: AdaScriptLibrarySource) {
        self.id = id
        self.source = source
    }
}

/// Stored as ada-library.json at the repository root. Sources share the consuming game's AdaScript module.
public struct AdaScriptLibraryManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var version: String
    public var api: Int
    public var sources: [String]
    public var dependencies: [AdaScriptLibraryDependency]

    public init(id: String, version: String, sources: [String], dependencies: [AdaScriptLibraryDependency] = []) {
        self.schemaVersion = 1
        self.id = id
        self.version = version
        self.api = 1
        self.sources = sources
        self.dependencies = dependencies
    }

    public func validate() throws {
        guard schemaVersion == 1, api == 1 else {
            throw AdaScriptLibraryError.invalid("Unsupported library schema or AdaScript API in \(id).")
        }
        guard Self.isIdentifier(id), version.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil else {
            throw AdaScriptLibraryError.invalid("Library requires a lowercase identifier and an exact major.minor.patch version.")
        }
        guard !sources.isEmpty, sources.count <= 256, Set(sources.map { $0.lowercased() }).count == sources.count else {
            throw AdaScriptLibraryError.invalid("Library \(id) requires 1–256 unique AdaScript source paths.")
        }
        for path in sources {
            guard Self.isSourcePath(path) else {
                throw AdaScriptLibraryError.invalid("Invalid AdaScript library source path: \(path).")
            }
        }
        guard Set(dependencies.map(\.id)).count == dependencies.count else {
            throw AdaScriptLibraryError.invalid("Duplicate dependencies in \(id).")
        }
        for dependency in dependencies {
            guard
                Self.isIdentifier(dependency.id), !dependency.source.provider.isEmpty,
                !dependency.source.location.isEmpty, !dependency.source.revision.isEmpty
            else {
                throw AdaScriptLibraryError.invalid("Invalid dependency in \(id).")
            }
        }
    }

    public static func isIdentifier(_ value: String) -> Bool {
        value.count <= 100 && value.range(of: #"^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$"#, options: .regularExpression) != nil
    }

    public static func isSourcePath(_ path: String) -> Bool {
        !path.isEmpty && path.count <= 240 && !path.contains("\\") && !path.contains(":")
            && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && path.hasSuffix(".ada")
            && path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy {
                    !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(" ")
                }
    }
}

public enum AdaScriptLibraryError: Error, Equatable, LocalizedError, Sendable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(message): message
        }
    }
}
