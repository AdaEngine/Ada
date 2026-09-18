import AdaScriptCompilerCore
import Foundation

/// A fresh actor owns the mutable graph for each installation; only complete results leave it.
actor AdaScriptLibraryResolution {
    struct Result: Sendable {
        var lock: AdaScriptLibraryLock
        var downloads: [String: AdaScriptLibraryDownload]
    }

    private let provider: any AdaScriptLibraryProvider
    private var existing: [String: AdaScriptLockedLibrary] = [:]
    private var resolved: [String: AdaScriptLockedLibrary] = [:]
    private var pending: [String: AdaScriptLibraryDownload] = [:]
    private var visiting: Set<String> = []

    init(provider: any AdaScriptLibraryProvider) {
        self.provider = provider
    }

    func resolve(previous: AdaScriptLibraryLock, download: AdaScriptLibraryDownload) async throws -> Result {
        var roots = previous.roots
        if !roots.contains(download.manifest.id) {
            roots.append(download.manifest.id)
        }
        pending[download.manifest.id] = download
        existing = Dictionary(uniqueKeysWithValues: previous.libraries.map { ($0.manifest.id, $0) })
        for id in roots.sorted() {
            guard let source = id == download.manifest.id ? download.source : existing[id]?.source else {
                throw AdaScriptLibraryError.invalid("Missing root library \(id).")
            }
            try await visit(id: id, source: source)
        }
        return Result(
            lock: AdaScriptLibraryLock(roots: roots.sorted(), libraries: resolved.values.sorted { $0.manifest.id < $1.manifest.id }),
            downloads: pending
        )
    }

    private func visit(id: String, source: AdaScriptLibrarySource) async throws {
        guard !visiting.contains(id) else {
            throw AdaScriptLibraryError.invalid("Library dependency cycle at \(id).")
        }
        if let entry = resolved[id] {
            guard entry.source == source else {
                throw AdaScriptLibraryError.invalid("Conflicting library revisions for \(id).")
            }
            return
        }
        guard visiting.count + resolved.count < 128 else {
            throw AdaScriptLibraryError.invalid("Too many library dependencies.")
        }
        visiting.insert(id)
        defer { visiting.remove(id) }
        let entry: AdaScriptLockedLibrary
        if let cached = existing[id], cached.source == source, pending[id] == nil {
            entry = cached
        } else {
            let fetched: AdaScriptLibraryDownload
            if let cached = pending[id] {
                fetched = cached
            } else {
                fetched = try await provider.download(source)
            }
            try fetched.validate()
            guard fetched.manifest.id == id, fetched.source == source else {
                throw AdaScriptLibraryError.invalid("Library identity or pinned revision mismatch for \(id).")
            }
            pending[id] = fetched
            entry = AdaScriptLockedLibrary(manifest: fetched.manifest, source: fetched.source, directory: UUID().uuidString)
        }
        for dependency in entry.manifest.dependencies {
            try await visit(id: dependency.id, source: dependency.source)
        }
        resolved[id] = entry
    }
}
