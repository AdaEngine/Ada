import Foundation

extension EditorProjectStore {
    /// Removes only the recent-project reference, preserving all project files.
    public func removeRecentProject(_ reference: EditorProjectReference) throws {
        try saveProjects(loadProjects().filter { $0.id != reference.id })
    }

    /// Updates the display name without changing the folder, build targets, or project identity.
    @discardableResult
    public func renameProject(_ reference: EditorProjectReference, to name: String) throws -> EditorProjectReference {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw EditorProjectStoreError.emptyProjectName
        }
        var references = try loadProjects()
        guard let index = references.firstIndex(where: { $0.id == reference.id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let url = resolveProjectURL(for: references[index])
        #if os(iOS) || os(tvOS) || os(visionOS)
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
        #endif
        let original = try ProjectSystem.loadProject(at: url, fileManager: fileManager)
        var project = original
        project.project.displayName = name
        try ProjectSystem.saveProject(project, at: url, fileManager: fileManager)
        references[index].name = name
        do {
            try saveProjects(references)
        } catch {
            try ProjectSystem.saveProject(original, at: url, fileManager: fileManager)
            throw error
        }
        return references[index]
    }

    public static func defaultStorageURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport: URL
        if let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            applicationSupport = applicationSupportURL
        } else {
            #if os(macOS)
                applicationSupport = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            #else
                applicationSupport = fileManager.temporaryDirectory
            #endif
        }

        return
            applicationSupport
            .appendingPathComponent("AdaEditor", isDirectory: true)
            .appendingPathComponent("projects.json", isDirectory: false)
    }

    public func loadProjects() throws -> [EditorProjectReference] {
        guard fileManager.fileExists(atPath: storageURL.path) else {
            return []
        }

        let data = try Data(contentsOf: storageURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([EditorProjectReference].self, from: data)
            .map(restoringProjectLocation)
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    public func saveProjects(_ projects: [EditorProjectReference]) throws {
        let directory = storageURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let recentProjects = Array(projects.sorted { $0.lastOpenedAt > $1.lastOpenedAt }.prefix(Self.maximumRecentProjectCount))
        let data = try encoder.encode(recentProjects)
        try data.write(to: storageURL, options: [.atomic])
    }

    /// Resolves a persisted project location against the current application container.
    ///
    /// iOS may assign a new data-container UUID when an application is reinstalled while
    /// preserving its Documents directory. Security-scoped bookmarks cover projects opened
    /// from Files or iCloud Drive, while `documentsRelativePath` keeps app-owned projects
    /// independent of that transient UUID.
    public func resolveProjectURL(for project: EditorProjectReference) -> URL {
        if let relativePath = validatedDocumentsRelativePath(
            project.documentsRelativePath ?? Self.legacyDocumentsRelativePath(from: project.path)
        ), let documentsDirectoryURL {
            return documentsDirectoryURL.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL
        }

        #if os(iOS) || os(tvOS) || os(visionOS)
            if let bookmarkData = project.bookmarkData {
                var isStale = false
                if let bookmarkedURL = try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) {
                    return bookmarkedURL.standardizedFileURL
                }
            }
        #endif

        return URL(fileURLWithPath: project.path, isDirectory: true).standardizedFileURL
    }

    func restoringProjectLocation(_ project: EditorProjectReference) -> EditorProjectReference {
        var restoredProject = project
        let resolvedURL = resolveProjectURL(for: project)
        restoredProject.path = resolvedURL.path
        if restoredProject.documentsRelativePath == nil {
            restoredProject.documentsRelativePath =
                documentsRelativePath(for: resolvedURL)
                ?? Self.legacyDocumentsRelativePath(from: project.path)
        }
        return restoredProject
    }

    func documentsRelativePath(for projectURL: URL) -> String? {
        guard let documentsDirectoryURL else {
            return nil
        }
        let documentsPath = documentsDirectoryURL.standardizedFileURL.path
        let projectPath = projectURL.standardizedFileURL.path
        guard projectPath.hasPrefix(documentsPath + "/") else {
            return nil
        }
        return validatedDocumentsRelativePath(String(projectPath.dropFirst(documentsPath.count + 1)))
    }

    static func legacyDocumentsRelativePath(from path: String) -> String? {
        guard
            let containerRange = path.range(of: "/Containers/Data/Application/"),
            let documentsRange = path.range(
                of: "/Documents/",
                range: containerRange.upperBound..<path.endIndex
            )
        else {
            return nil
        }
        let relativePath = String(path[documentsRange.upperBound...])
        return relativePath.isEmpty ? nil : relativePath
    }

    func makeBookmarkData(for projectURL: URL) -> Data? {
        #if os(iOS) || os(tvOS) || os(visionOS)
            return try? projectURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        #else
            return nil
        #endif
    }

    private func validatedDocumentsRelativePath(_ relativePath: String?) -> String? {
        guard let relativePath, !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            return nil
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return relativePath
    }
}
