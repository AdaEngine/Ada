#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct EditorCommunityPackageManifest: Codable, Sendable {
    struct File: Codable, Sendable {
        let path: String
        let size: Int
        let sha256: String
    }
    let formatVersion: Int
    let runtime: String
    let apiVersion: Int
    let files: [File]

    func validate() throws {
        guard formatVersion == 1, [1, 2].contains(apiVersion), runtime == "adascript", !files.isEmpty, files.count <= 512 else { throw Failure.invalidPackage }
        var names = Set<String>()
        var total = 0
        for file in files {
            guard Self.validPath(file.path), file.size >= 0, file.size <= 16 * 1024 * 1024,
                  file.sha256.count == 64, file.sha256.allSatisfy({ $0.isHexDigit }),
                  names.insert(file.path.lowercased()).inserted else { throw Failure.invalidPackage }
            if file.path.hasPrefix("Sources/"), file.size > 512 * 1024 { throw Failure.invalidPackage }
            if ["ada-game.json", ".ada/project.json"].contains(file.path), file.size > 256 * 1024 { throw Failure.invalidPackage }
            total += file.size
            guard total <= 64 * 1024 * 1024 else { throw Failure.invalidPackage }
        }
        guard names.contains("ada-game.json"), names.contains(".ada/project.json"), names.contains(where: { $0.hasPrefix("sources/") && $0.hasSuffix(".ada") }) else { throw Failure.invalidPackage }
    }

    static func validPath(_ path: String) -> Bool {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 512, pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              path.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-").contains($0) }) else { return false }
        if path == "ada-game.json" || path == ".ada/project.json" { return true }
        if path.hasPrefix("Sources/") { return path.hasSuffix(".ada") }
        return path.hasPrefix("Assets/") && ["png", "jpg", "jpeg", "wav", "ogg", "ascn", "tilemap", "tileset", "json", "glb", "gltf", "bin"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    enum Failure: Error, LocalizedError {
        case invalidPackage
        case incompatibleProject
        case corruptFile
        var errorDescription: String? {
            switch self {
            case .invalidPackage: "This world contains an invalid game package."
            case .incompatibleProject: "This world requires features unavailable in this Studio player."
            case .corruptFile: "The game download failed its integrity check. Please try again."
            }
        }
    }
}

actor EditorCommunityPackageStore {
    static let shared = EditorCommunityPackageStore()
    private let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AdaStudioCommunity", isDirectory: true)
    }

    func load(game: EditorCommunityGame, client: EditorCommunityClient) async throws -> URL {
        guard case .adaScript(let release) = game.runtime, UUID(uuidString: game.id) != nil, UUID(uuidString: release) != nil else {
            throw EditorCommunityPackageManifest.Failure.invalidPackage
        }
        // A manually opened preview from another origin must not share a game's saves or cache.
        let namespace = EditorCommunityPackageManifest.digest(Data((client.server.absoluteString + "|" + game.playURL.absoluteString).utf8))
        let base = root.appendingPathComponent(namespace).appendingPathComponent(game.id)
        let installed = base.appendingPathComponent(release)
        let manifestData = try await fetch("ada-manifest.json", game: game, release: release, client: client)
        guard manifestData.count <= 256 * 1024 else { throw EditorCommunityPackageManifest.Failure.invalidPackage }
        let manifest = try JSONDecoder().decode(EditorCommunityPackageManifest.self, from: manifestData)
        try manifest.validate()
        guard manifest.apiVersion == game.apiVersion else { throw EditorCommunityPackageManifest.Failure.incompatibleProject }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let staging = base.appendingPathComponent("download-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        var fullyCached = true
        for file in manifest.files {
            try Task.checkCancellation()
            let cachedURL = installed.appendingPathComponent(file.path)
            let cached = try? Data(contentsOf: cachedURL)
            let data: Data
            if let cached, cached.count == file.size, EditorCommunityPackageManifest.digest(cached) == file.sha256 { data = cached }
            else { fullyCached = false; data = try await fetch(file.path, game: game, release: release, client: client) }
            guard data.count == file.size, EditorCommunityPackageManifest.digest(data) == file.sha256 else { throw EditorCommunityPackageManifest.Failure.corruptFile }
            let target = staging.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
        try Task.checkCancellation()
        // Recheck moderation and release after download, including cache hits.
        if game.isPreview {
            let current = try await fetch("ada-manifest.json", game: game, release: release, client: client)
            guard current == manifestData else { throw EditorCommunityClient.CommunityError.unavailable }
        } else {
            let current = try await client.game(id: game.id)
            guard current.runtime == game.runtime, current.playURL == game.playURL else { throw EditorCommunityClient.CommunityError.unavailable }
        }
        if fullyCached { return installed }
        if FileManager.default.fileExists(atPath: installed.path) { try FileManager.default.removeItem(at: installed) }
        try FileManager.default.moveItem(at: staging, to: installed)
        return installed
    }

    private func fetch(_ path: String, game: EditorCommunityGame, release: String, client: EditorCommunityClient) async throws -> Data {
        var components = URLComponents(url: game.playURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "release", value: release)]
        guard let url = components?.url else { throw EditorCommunityPackageManifest.Failure.invalidPackage }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (data, response) = try await client.transport(request)
        guard response.statusCode == 200 else { throw EditorCommunityClient.CommunityError.unavailable }
        guard data.count <= 16 * 1024 * 1024 else { throw EditorCommunityPackageManifest.Failure.invalidPackage }
        return data
    }
}
