import Foundation

enum EditorSourceControlProvider: String, CaseIterable, Codable, Sendable {
    case git, lore

    static var defaultForNewProjects: Self { Self.lore.isAvailable ? .lore : .git }

    var title: String { self == .git ? "Git" : "Lore" }
    var directoryName: String { self == .git ? ".git" : ".lore" }
    var initializationTitle: String { self == .git ? "Create .git" : "Create .lore" }
    var supportsStash: Bool { self == .git }
    var isAvailable: Bool {
        if self == .git { return true }
        #if canImport(Lore)
        return true
        #else
        return false
        #endif
    }

    func makeService() -> any GitRepositoryServicing {
        switch self {
        case .git: GitRepositoryService()
        case .lore: LoreRepositoryService()
        }
    }

    static func settingsURL(in project: URL) -> URL {
        project.appendingPathComponent(".ada/workspace/source-control.json")
    }

    /// A saved choice wins over discovery, including when both repositories exist.
    static func load(in project: URL) -> Self {
        if let data = try? Data(contentsOf: settingsURL(in: project)),
           let saved = try? JSONDecoder().decode(Self.self, from: data) { return saved }
        var directory = project.standardizedFileURL
        while true {
            for provider in allCases where FileManager.default.fileExists(atPath: directory.appendingPathComponent(provider.directoryName).path) {
                return provider
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { return .git }
            directory = parent
        }
    }

    func save(in project: URL) throws {
        let url = Self.settingsURL(in: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
