import AdaScriptCompilerCore
import Foundation

/// Downloads never execute library code. A single atomic lock write activates a complete dependency graph.
actor EditorAdaScriptLibraryManager {
    static let shared = EditorAdaScriptLibraryManager()
    private let provider: any AdaScriptLibraryProvider
    private var busyProjects: Set<String> = []

    init(provider: any AdaScriptLibraryProvider = GitHubAdaScriptLibraryProvider()) {
        self.provider = provider
    }

    func install(_ source: AdaScriptLibrarySource, at projectURL: URL) async throws -> AdaScriptLibraryLock {
        let key = projectURL.resolvingSymlinksInPath().path
        guard busyProjects.insert(key).inserted else {
            throw AdaScriptLibraryError.invalid("A library operation is already running.")
        }
        defer { busyProjects.remove(key) }
        let previous = try AdaScriptLibraryLock.load(at: projectURL)
        let download = try await provider.download(source)
        try download.validate()
        let resolution = try await AdaScriptLibraryResolution(provider: provider).resolve(previous: previous, download: download)
        return try commit(resolution.lock, downloads: resolution.downloads, replacing: previous, at: projectURL)
    }

    func remove(_ id: String, at projectURL: URL) throws -> AdaScriptLibraryLock {
        guard !busyProjects.contains(projectURL.resolvingSymlinksInPath().path) else {
            throw AdaScriptLibraryError.invalid("A library operation is already running.")
        }
        let previous = try AdaScriptLibraryLock.load(at: projectURL)
        var lock = previous
        lock.roots.removeAll { $0 == id }
        lock.libraries = try lock.orderedLibraries()
        return try commit(lock, downloads: [:], replacing: previous, at: projectURL)
    }

    func restore(at projectURL: URL) async throws -> AdaScriptLibraryLock {
        let key = projectURL.resolvingSymlinksInPath().path
        guard busyProjects.insert(key).inserted else {
            throw AdaScriptLibraryError.invalid("A library operation is already running.")
        }
        defer { busyProjects.remove(key) }
        let previous = try AdaScriptLibraryLock.load(at: projectURL)
        var lock = previous
        var downloads: [String: AdaScriptLibraryDownload] = [:]
        for index in lock.libraries.indices {
            let entry = lock.libraries[index]
            let download = try await provider.download(entry.source)
            try download.validate()
            guard download.manifest == entry.manifest, download.source == entry.source else {
                throw AdaScriptLibraryError.invalid("Published library changed: \(entry.manifest.id).")
            }
            downloads[entry.manifest.id] = download
            lock.libraries[index].directory = UUID().uuidString
        }
        return try commit(lock, downloads: downloads, replacing: previous, at: projectURL)
    }

    private func commit(
        _ lock: AdaScriptLibraryLock,
        downloads: [String: AdaScriptLibraryDownload],
        replacing previous: AdaScriptLibraryLock,
        at projectURL: URL
    ) throws -> AdaScriptLibraryLock {
        _ = try lock.orderedLibraries()
        try Task.checkCancellation()
        guard try AdaScriptLibraryLock.load(at: projectURL) == previous else {
            throw AdaScriptLibraryError.invalid("Libraries changed during installation. Retry the operation.")
        }
        let fileManager = FileManager.default
        var created: [URL] = []
        var committed = false
        defer {
            if !committed {
                for url in created { try? fileManager.removeItem(at: url) }
            }
        }
        for library in lock.libraries {
            guard let download = downloads[library.manifest.id] else {
                continue
            }
            let root = try AdaScriptLibraryLock.containedURL(".ada/libraries/\(library.directory)", in: projectURL)
            guard !fileManager.fileExists(atPath: root.path) else {
                throw AdaScriptLibraryError.invalid("Library installation already exists.")
            }
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            created.append(root)
            for (path, data) in download.files {
                let file = try AdaScriptLibraryLock.containedURL(path, in: root)
                try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            }
        }
        _ = try lock.loadSources(at: projectURL)
        let destination = try AdaScriptLibraryLock.containedURL(AdaScriptLibraryLock.relativePath, in: projectURL)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(lock).write(to: destination, options: .atomic)
        committed = true
        return lock
    }
}
