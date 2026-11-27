import AdaAssets
@_spi(Internal) import AdaRender
import Foundation

actor EditorExternalAssetLibrary {
    enum Store: String, CaseIterable, Codable, Sendable {
        case fab, unity

        var title: String { self == .fab ? "Fab" : "Unity Asset Store" }
        var host: String { self == .fab ? "www.fab.com" : "assetstore.unity.com" }
        var home: URL? { URL(string: "https://" + host) }
    }

    struct Listing: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let store: Store
        let key: String
        let url: URL
        let title: String
        var model: UUID?
        var cover: UUID?
    }

    enum Failure: LocalizedError {
        case listing, name, unavailable, file, location

        var errorDescription: String? {
            switch self {
            case .listing: "Enter a Fab or Unity Asset Store listing link."
            case .name: "Enter an asset name between 1 and 120 characters."
            case .unavailable: "This asset is no longer available in the library."
            case .file: "Choose a supported local asset file."
            case .location: "The external asset library location is unavailable."
            }
        }
    }

    private let project: URL
    private let directory: URL
    private let fileManager = FileManager.default

    init(project: URL) {
        self.project = project.standardizedFileURL.resolvingSymlinksInPath()
        directory = self.project.appendingPathComponent(".ada-external-assets", isDirectory: true)
    }

    static func identity(_ raw: String) throws -> (store: Store, key: String, url: URL) {
        guard raw.utf8.count <= 2048, var url = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil else { throw Failure.listing }
        let segments = url.path.split(separator: "/").map(String.init)
        let store: Store
        let key: String
        switch url.host?.lowercased() {
        case "fab.com", "www.fab.com":
            guard segments.count == 2, segments[0] == "listings", let id = UUID(uuidString: segments[1]) else { throw Failure.listing }
            store = .fab
            key = id.uuidString.lowercased()
            url.path = "/listings/" + key
        case "assetstore.unity.com":
            let parts = segments
            guard parts.count >= 2, let id = parts.last?.split(separator: "-").last,
                  parts.first == "packages", parts.dropFirst().allSatisfy({
                      $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
                  }),
                  !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }) else { throw Failure.listing }
            store = .unity
            key = String(id)
            url.path = "/" + parts.joined(separator: "/")
        default: throw Failure.listing
        }
        url.host = store.host
        url.query = nil
        url.fragment = nil
        guard let canonical = url.url else { throw Failure.listing }
        return (store, key, canonical)
    }

    func search(_ query: String = "", store: Store? = nil) throws -> [Listing] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try read().filter {
            (store == nil || $0.store == store) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
        }.sorted { ($0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending) }
    }

    func add(title: String, link: String) throws -> Listing {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...120).contains(title.count), title.utf8.count <= 480 else { throw Failure.name }
        let source = try Self.identity(link)
        var listings = try read()
        if let existing = listings.first(where: { $0.store == source.store && $0.key == source.key }) {
            return existing
        }
        guard listings.count < 2_000 else { throw Failure.location }
        let listing = Listing(id: UUID(), store: source.store, key: source.key, url: source.url, title: title)
        listings.append(listing)
        try write(listings)
        return listing
    }

    func modelURL(for listing: Listing) -> URL? {
        file(for: listing.model, suffix: "glb")
    }

    func listing(id: UUID) throws -> Listing? {
        try read().first { $0.id == id }
    }

    func coverURL(for listing: Listing) -> URL? {
        file(for: listing.cover, suffix: "cover")
    }

    func thumbnailURL(for listing: Listing) -> URL? {
        file(for: listing.model, suffix: "preview-v1.png")
    }

    func image(at url: URL) -> Image? {
        guard let data = try? EditorStudioPluginManifest.readFile(url, limit: 4_000_000),
              let decoded = try? Image.decodedImportByteCount(from: data), decoded <= 4_194_304 else {
                  return nil
              }
        return try? Image.decode(from: data)
    }

    func attach(_ source: URL, listing: UUID, cover: Bool) throws {
        let format = source.pathExtension.lowercased()
        guard (cover ? ["jpeg", "jpg", "png"] : ["glb"]).contains(format) else { throw Failure.file }
        let data: Data
        if cover {
            data = try EditorStudioPluginManifest.readFile(source, limit: 4_000_000)
            guard try Image.decodedImportByteCount(from: data) <= 4_194_304 else { throw Failure.file }
            _ = try Image.decode(from: data)
        } else {
            data = try validatedModelBytes(source)
        }
        try Task.checkCancellation()
        var all = try read()
        guard let index = all.firstIndex(where: { $0.id == listing }) else { throw Failure.unavailable }
        let id = UUID()
        let suffix = cover ? "cover" : "glb"
        let previous = cover ? all[index].cover : all[index].model
        let output = try managedFile(id, suffix: suffix)
        try data.write(to: output, options: .withoutOverwriting)
        do {
            if cover { all[index].cover = id } else { all[index].model = id }
            try write(all)
        } catch {
            try? fileManager.removeItem(at: output)
            throw error
        }
        if let previous = file(for: previous, suffix: suffix) { try? fileManager.removeItem(at: previous) }
        if !cover, let preview = file(for: previous, suffix: "preview-v1.png") { try? fileManager.removeItem(at: preview) }
    }

    func removeModel(listing: UUID) throws {
        var all = try read()
        guard let index = all.firstIndex(where: { $0.id == listing }) else { throw Failure.unavailable }
        try Task.checkCancellation()
        guard let revision = all[index].model else {
            return
        }
        let original = file(for: revision, suffix: "glb")
        let staged = try managedFile(revision, suffix: "removing")
        if let original { try fileManager.moveItem(at: original, to: staged) }
        do {
            all[index].model = nil
            try write(all)
        } catch {
            if let original { try? fileManager.moveItem(at: staged, to: original) }
            throw error
        }
        if original != nil { try? fileManager.removeItem(at: staged) }
        if let preview = file(for: revision, suffix: "preview-v1.png") { try? fileManager.removeItem(at: preview) }
    }

    func reconcile() throws {
        try Task.checkCancellation()
        let all = try read()
        let root = try libraryDirectory()
        guard try regularFile(root.appendingPathComponent("listings.json")) else {
            return
        }
        let models = Set(all.compactMap(\.model))
        let covers = Set(all.compactMap(\.cover))
        let files = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        for url in files {
            let parts = url.lastPathComponent.split(separator: ".", maxSplits: 1)
            guard parts.count == 2, let id = UUID(uuidString: String(parts[0])), try regularFile(url) else { continue }
            switch parts[1] {
            case "removing" where models.contains(id):
                let model = try managedFile(id, suffix: "glb")
                if fileManager.fileExists(atPath: model.path) { try fileManager.removeItem(at: url) } else { try fileManager.moveItem(at: url, to: model) }
            case "removing":
                try fileManager.removeItem(at: url)
            case "glb", "preview-v1.png":
                if !models.contains(id) { try fileManager.removeItem(at: url) }
            case "cover":
                if !covers.contains(id) { try fileManager.removeItem(at: url) }
            default: break
            }
        }
    }

    func cacheThumbnail(_ image: Image, listing: UUID, revision: UUID) throws {
        try Task.checkCancellation()
        let png = try image.pngData()
        guard png.count <= 1_000_000, try read().contains(where: { $0.id == listing && $0.model == revision }) else {
            return
        }
        try Task.checkCancellation()
        let url = try managedFile(revision, suffix: "preview-v1.png")
        try png.write(to: url, options: .atomic)
    }

    func modelImport(listing: UUID, assets: URL) throws -> URL {
        guard let listing = try read().first(where: { $0.id == listing }), let model = modelURL(for: listing),
              let revision = listing.model else { throw Failure.unavailable }
        let resolved = canonicalLocation(assets.standardizedFileURL)
        guard resolved.pathComponents.starts(with: project.pathComponents), resolved.pathComponents.count > project.pathComponents.count else {
            throw Failure.location
        }
        let target = resolved.appendingPathComponent("ExternalAssets/\(listing.id.uuidString)", isDirectory: true)
        guard canonicalLocation(target).pathComponents == target.pathComponents else { throw Failure.location }
        let destination = target.appendingPathComponent("model-\(revision.uuidString).glb")
        let bytes = try validatedModelBytes(model)
        if try regularFile(destination) {
            guard try EditorStudioPluginManifest.readFile(destination, limit: bytes.count) == bytes else { throw Failure.location }
            return destination
        }
        try Task.checkCancellation()
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let temporary = target.appendingPathComponent(".\(UUID().uuidString).glb")
        defer { try? fileManager.removeItem(at: temporary) }
        try bytes.write(to: temporary, options: .withoutOverwriting)
        try Task.checkCancellation()
        try fileManager.moveItem(at: temporary, to: destination)
        return destination
    }

    private func validatedModelBytes(_ url: URL) throws -> Data {
        let data = try EditorStudioPluginManifest.readFile(url, limit: 32 * 1024 * 1024)
        try EditorModelAssetImporter.requireSelfContainedGLB(data)
        _ = try NativeGLTFLoader().load(data: data, allowExternalResources: false)
        return data
    }

    private func read() throws -> [Listing] {
        let url = try libraryDirectory().appendingPathComponent("listings.json")
        guard try regularFile(url) else {
            return []
        }
        let data = try EditorStudioPluginManifest.readFile(url, limit: 4_000_000)
        let listings = try JSONDecoder().decode([Listing].self, from: data)
        let fileIDs = listings.flatMap { [$0.model, $0.cover].compactMap { $0 } }
        guard listings.count <= 2_000, Set(listings.map(\.id)).count == listings.count,
              Set(fileIDs).count == fileIDs.count else { throw Failure.location }
        var keys: Set<String> = []
        for listing in listings {
            let identity = try Self.identity(listing.url.absoluteString)
            guard identity.store == listing.store, identity.key == listing.key, identity.url == listing.url,
                  (1...120).contains(listing.title.count), listing.title.utf8.count <= 480,
                  keys.insert(listing.store.rawValue + "/" + listing.key).inserted else { throw Failure.location }
        }
        return listings
    }

    private func write(_ listings: [Listing]) throws {
        let root = try libraryDirectory()
        if !fileManager.fileExists(atPath: root.path) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        }
        let url = root.appendingPathComponent("listings.json")
        _ = try regularFile(url)
        let data = try JSONEncoder().encode(listings)
        guard data.count <= 4_000_000 else { throw Failure.location }
        try data.write(to: url, options: .atomic)
    }

    private func libraryDirectory() throws -> URL {
        guard directory.resolvingSymlinksInPath().pathComponents == directory.pathComponents else { throw Failure.location }
        return directory
    }

    private func managedFile(_ id: UUID, suffix: String) throws -> URL {
        let url = try libraryDirectory().appendingPathComponent(id.uuidString + "." + suffix)
        _ = try regularFile(url)
        return url
    }

    private func file(for id: UUID?, suffix: String) -> URL? {
        guard let id, let url = try? managedFile(id, suffix: suffix), (try? regularFile(url)) == true else {
            return nil
        }
        return url
    }

    private func regularFile(_ url: URL) throws -> Bool {
        guard url.resolvingSymlinksInPath().pathComponents == url.pathComponents else { throw Failure.location }
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw Failure.location }
        return true
    }

    /// Windows does not expand short path components when the leaf does not
    /// exist yet. Resolve the existing ancestor before checking containment.
    private func canonicalLocation(_ url: URL) -> URL {
        let base = url.deletingLastPathComponent()
        if base.pathComponents.count >= url.pathComponents.count ||
            fileManager.fileExists(atPath: url.path) ||
            (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return url.resolvingSymlinksInPath().standardizedFileURL
        }
        return canonicalLocation(base).appendingPathComponent(url.lastPathComponent, isDirectory: url.hasDirectoryPath)
    }
}
