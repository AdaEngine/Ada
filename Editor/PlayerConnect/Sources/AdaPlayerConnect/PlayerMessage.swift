import Foundation

public enum PlayerConnectError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

/// Versioned, length-prefixed JSON messages. A session must pair before accepting project data.
public struct PlayerMessage: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case pair, paired, deploy, stop, status, log, failure }
    public var version: Int = 1
    public let kind: Kind
    public var text: String?
    public var project: PlayerProjectSnapshot?

    public init(_ kind: Kind, text: String? = nil, project: PlayerProjectSnapshot? = nil) {
        self.kind = kind
        self.text = text
        self.project = project
    }
}

/// A bounded portable project; installation always creates a fresh directory, never merges stale assets.
public struct PlayerProjectSnapshot: Codable, Sendable {
    public struct File: Codable, Sendable {
        public let path: String
        public let data: Data
        public init(path: String, data: Data) { self.path = path; self.data = data }
    }
    public static let maximumBytes = 64 * 1024 * 1024
    public static let maximumFiles = 4096
    public let files: [File]
    public init(files: [File]) { self.files = files }

    public static func validatePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 1024,
              !path.contains("\\"), !path.contains(":"), !path.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PlayerConnectError.invalid("Invalid project path: \(path.prefix(120))")
        }
    }

    public func validate() throws {
        guard !files.isEmpty, files.count <= Self.maximumFiles else {
            throw PlayerConnectError.invalid("Project must contain 1–4096 files.")
        }
        var paths = Set<String>()
        var size = 0
        for file in files {
            try Self.validatePath(file.path)
            // Avoid aliases on case-insensitive Apple filesystems, including Unicode normalization.
            let key = file.path.precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(key).inserted else { throw PlayerConnectError.invalid("Duplicate path: \(file.path)") }
            size += file.data.count
            guard size <= Self.maximumBytes else { throw PlayerConnectError.invalid("Project exceeds the 64 MB preview limit.") }
        }
        for path in paths {
            var parts = path.split(separator: "/")
            while parts.count > 1 {
                parts.removeLast()
                guard !paths.contains(parts.joined(separator: "/")) else {
                    throw PlayerConnectError.invalid("A file is also used as a directory.")
                }
            }
        }
        guard paths.contains(".ada/project.json") else { throw PlayerConnectError.invalid("Missing .ada/project.json.") }
    }

    public func install(in parent: URL) throws -> URL {
        try validate()
        let directory = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            for file in files {
                let destination = directory.appendingPathComponent(file.path)
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: destination, options: .atomic)
            }
            return directory
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }
}
