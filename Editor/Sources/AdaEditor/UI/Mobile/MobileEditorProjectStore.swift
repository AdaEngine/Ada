import Foundation

struct MobileEditorProject: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var prompt: String?

}

struct MobileEditorProjectStore {
    let directory: URL

    private var indexURL: URL { directory.appendingPathComponent("projects.json") }

    func load() throws -> [MobileEditorProject] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        // Hide the retired bundled sample without deleting any on-device files.
        return try JSONDecoder().decode([MobileEditorProject].self, from: Data(contentsOf: indexURL))
            .filter { $0.id.uuidString != "7B0A53A1-BCF6-40A9-9916-06AA92342509" }
    }

    func save(_ projects: [MobileEditorProject]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(projects).write(to: indexURL, options: .atomic)
    }

    func rename(id: UUID, to title: String) throws -> [MobileEditorProject] {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw Failure(message: "Enter a project name.") }
        var projects = try load()
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            throw Failure(message: "Project not found.")
        }
        let projectURL = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        let metadataURL = ProjectSystem.metadataURL(forProjectAt: projectURL)
        let oldMetadata = FileManager.default.fileExists(atPath: metadataURL.path) ? try Data(contentsOf: metadataURL) : nil
        if oldMetadata != nil {
            var metadata = try ProjectSystem.loadProject(at: projectURL)
            metadata.project.name = title
            metadata.project.displayName = title
            try ProjectSystem.saveProject(metadata, at: projectURL)
        }
        projects[index].title = title
        do {
            try save(projects)
        } catch {
            if let oldMetadata { try oldMetadata.write(to: metadataURL, options: .atomic) }
            throw error
        }
        return projects
    }

    func delete(id: UUID) throws -> [MobileEditorProject] {
        let projects = try load().filter { $0.id != id }
        let projectURL = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        let stagingURL = directory.appendingPathComponent(".deleted-\(UUID().uuidString)", isDirectory: true)
        let hasFiles = FileManager.default.fileExists(atPath: projectURL.path)
        if hasFiles { try FileManager.default.moveItem(at: projectURL, to: stagingURL) }
        do {
            try save(projects)
        } catch {
            if hasFiles { try FileManager.default.moveItem(at: stagingURL, to: projectURL) }
            throw error
        }
        // Once the index is committed, leftover staging files are no longer a project.
        if hasFiles { try? FileManager.default.removeItem(at: stagingURL) }
        return projects
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
