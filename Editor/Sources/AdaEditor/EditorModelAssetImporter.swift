import Foundation

/// Copies a model and its local dependencies as one portable, collision-free asset bundle.
enum EditorModelAssetImporter {
    private struct Document: Decodable {
        struct Resource: Decodable { var uri: String? }
        var buffers: [Resource]?
        var images: [Resource]?
    }

    static func copy(_ source: URL, to destination: URL, fileManager: FileManager = .default) throws -> URL {
        let document = try JSONDecoder().decode(Document.self, from: jsonData(at: source))
        let uris = ((document.buffers ?? []) + (document.images ?? [])).compactMap(\.uri).filter { !$0.hasPrefix("data:") }
        guard !uris.isEmpty else {
            let target = uniqueURL(source.lastPathComponent, in: destination, fileManager: fileManager)
            try fileManager.copyItem(at: source, to: target)
            return target
        }
        let sourceRoot = source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        var resources: [String: URL] = [:]
        for uri in Set(uris) {
            guard let parsed = URL(string: uri), parsed.scheme == nil, parsed.host == nil, parsed.query == nil, parsed.fragment == nil,
                let path = uri.removingPercentEncoding, !path.hasPrefix("/") else {
                throw Failure(message: "Model dependency must be a local relative file: \(uri)")
            }
            let file = sourceRoot.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard file.path.hasPrefix(sourceRoot.path + "/"), file != source.resolvingSymlinksInPath().standardizedFileURL,
                (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                throw Failure(message: "Keep model dependencies beneath its directory: \(uri)")
            }
            resources[String(file.path.dropFirst(sourceRoot.path.count + 1))] = file
        }
        let target = uniqueURL(source.deletingPathExtension().lastPathComponent, in: destination, fileManager: fileManager)
        let stage = destination.appendingPathComponent(".model-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stage) }
        try fileManager.copyItem(at: source, to: stage.appendingPathComponent(source.lastPathComponent))
        for (path, file) in resources {
            let output = stage.appendingPathComponent(path)
            try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: file, to: output)
        }
        try fileManager.moveItem(at: stage, to: target)
        return target.appendingPathComponent(source.lastPathComponent)
    }

    private static func uniqueURL(_ name: String, in destination: URL, fileManager: FileManager) -> URL {
        let input = URL(fileURLWithPath: name)
        var candidate = destination.appendingPathComponent(name)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let ext = input.pathExtension
            candidate = destination.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-\(suffix)" + (ext.isEmpty ? "" : ".\(ext)"))
            suffix += 1
        }
        return candidate
    }

    private static func jsonData(at url: URL) throws -> Data {
        if url.pathExtension.lowercased() == "gltf" {
            return try Data(contentsOf: url)
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let header = try file.read(upToCount: 20), header.count == 20 else { throw Failure(message: "Invalid GLB header.") }
        func uint32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(header[offset + $1]) << (8 * $1) }
        }
        let count = Int(uint32(12))
        guard uint32(0) == 0x46546C67, uint32(4) == 2, uint32(16) == 0x4E4F534A, count > 0, count <= 16 * 1024 * 1024,
            let json = try file.read(upToCount: count), json.count == count else { throw Failure(message: "Invalid GLB JSON chunk.") }
        return json
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
