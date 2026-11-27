import AdaScriptCompilerCore
import AdaStudioCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

enum EditorStudioPluginInstaller {
    private static let receiptName = ".install-receipt.json"

    static func install(_ archive: URL, in project: URL) throws -> String {
        let sizeLimit = 512 * 1024
        let failure = EditorStudioPluginManifest.Failure.archive
        let archiveBytes = try EditorStudioPluginManifest.readFile(archive, limit: sizeLimit)
        let files: [StudioFile]
        do {
            files = try StudioArchive.decode(
                archiveBytes,
                maximumBytes: sizeLimit,
                maximumFileBytes: EditorStudioPluginManifest.fileLimit,
                maximumFiles: 12,
                regularFilesOnly: true,
                permits: { path in
                    if path == EditorStudioPluginManifest.filename {
                        return true
                    }
                    let parts = path.split(separator: ".", omittingEmptySubsequences: false)
                    guard parts.count == 2, !parts[0].isEmpty, ["ada", "ui"].contains(parts[1]) else {
                        return false
                    }
                    return parts[0].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
                }
            )
        } catch { throw failure }
        guard let manifestFile = files.first(where: { $0.path == EditorStudioPluginManifest.filename }) else { throw failure }
        let manifest = try EditorStudioPluginManifest.decode(manifestFile.data)
        let sources: [AdaScriptCompilerSource] = try files.filter { $0.path.hasSuffix(".ada") }.map {
            guard let text = String(data: $0.data, encoding: .utf8) else { throw failure }
            return .init(path: $0.path, source: text)
        }
        let tools = try AdaScriptSchemaParser.parseTools(sources: sources)
        guard tools.count == 1, tools.first?.id == manifest.id else { throw failure }
        #if os(Windows)
        guard tools.first?.platforms.contains(.windows) == true else { throw failure }
        #elseif os(macOS)
        guard tools.first?.platforms.contains(.macOS) == true else { throw failure }
        #endif
        let root = project.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("Tools", isDirectory: true)
        let destination = root.appendingPathComponent(manifest.id, isDirectory: true)
        guard root.resolvingSymlinksInPath().pathComponents == root.pathComponents,
              destination.resolvingSymlinksInPath().pathComponents == destination.pathComponents else { throw failure }
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            let installed = try manager.contentsOfDirectory(atPath: destination.path).filter { $0 != receiptName }
            guard Set(installed) == Set(files.map(\.path)), try files.allSatisfy({
                try EditorStudioPluginManifest.readFile(destination.appendingPathComponent($0.path)) == $0.data
            }) else { throw EditorStudioPluginManifest.Failure.destination }
            return manifest.id
        }
        let existing = try EditorStudioToolDiscovery.discover(at: project)
        guard !existing.contains(where: { $0.schema.id == manifest.id }) else { throw EditorStudioPluginManifest.Failure.destination }
        let staging = root.appendingPathComponent(".studio-plugin-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        for file in files {
            try file.data.write(to: staging.appendingPathComponent(file.path), options: .withoutOverwriting)
        }
        let receipt = Dictionary(uniqueKeysWithValues: files.map { ($0.path, fingerprint($0.data)) })
        try JSONEncoder().encode(receipt).write(to: staging.appendingPathComponent(receiptName), options: .withoutOverwriting)
        try manager.moveItem(at: staging, to: destination)
        return manifest.id
    }

    static func uninstall(_ definition: EditorStudioToolDefinition, in project: URL) throws {
        let root = project.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("Tools", isDirectory: true)
        let directory = root.appendingPathComponent(definition.schema.id, isDirectory: true)
        guard definition.manifest != nil, definition.directory.pathComponents == directory.pathComponents,
              root.resolvingSymlinksInPath().pathComponents == root.pathComponents,
              directory.resolvingSymlinksInPath().pathComponents == directory.pathComponents else {
            throw EditorStudioPluginManifest.Failure.destination
        }
        let owned = try ownedFiles(in: directory)
        let manager = FileManager.default
        let retired = root.appendingPathComponent(".studio-retired-" + UUID().uuidString, isDirectory: true)
        try manager.moveItem(at: directory, to: retired)
        for name in owned { try manager.removeItem(at: retired.appendingPathComponent(name)) }
        try manager.removeItem(at: retired.appendingPathComponent(receiptName))
        if try manager.contentsOfDirectory(atPath: retired.path).isEmpty { try manager.removeItem(at: retired) }
    }

    static func isManaged(_ definition: EditorStudioToolDefinition) -> Bool {
        (try? ownedFiles(in: definition.directory)) != nil
    }

    private static func ownedFiles(in directory: URL) throws -> [String] {
        let failure = EditorStudioPluginManifest.Failure.destination
        let receipt = directory.appendingPathComponent(receiptName)
        let bytes = try EditorStudioPluginManifest.readFile(receipt)
        let digests = try JSONDecoder().decode([String: String].self, from: bytes)
        let installed = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != receiptName }
        guard !installed.isEmpty, installed.count <= 12, Set(digests.keys) == Set(installed),
              installed.contains(EditorStudioPluginManifest.filename) else { throw failure }
        for name in installed {
            let data = try EditorStudioPluginManifest.readFile(directory.appendingPathComponent(name))
            guard fingerprint(data) == digests[name] else { throw failure }
        }
        return installed
    }

    private static func fingerprint(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }
}
