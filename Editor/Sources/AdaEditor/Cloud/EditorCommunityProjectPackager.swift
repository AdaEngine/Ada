import AdaPlayerConnect
import Foundation

enum EditorCommunityProjectPackager {
    /// Uses the same resolved sources as device preview, then enforces the public player contract.
    @concurrent
    static func archive(projectURL: URL) async throws -> Data {
        let project = try ProjectSystem.loadProject(at: projectURL)
        guard (project.paths.assets ?? "Assets") == "Assets",
              project.paths.resourceRoots.allSatisfy({ $0 == "Assets" }), project.runtime.entry.view == nil else {
            throw EditorPublicationError("Community publishing requires Assets resources and a scene or startup system; script UI is unsupported.")
        }
        let snapshot = try await EditorPlayerProjectPackager.prepare(at: projectURL)
        var files = snapshot.files
        guard let index = files.firstIndex(where: { $0.path == ".ada/project.json" }) else {
            throw EditorCommunityPackageManifest.Failure.invalidPackage
        }
        var portable = try JSONDecoder().decode(AdaProject.self, from: files[index].data)
        portable.paths.sources = "Sources"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        files[index] = .init(path: ".ada/project.json", data: try encoder.encode(portable))
        files = files.map { file in
            file.path.hasPrefix("PlayerSources/")
                ? .init(path: "Sources/" + file.path.dropFirst("PlayerSources/".count), data: file.data) : file
        }
        let plugins = try EditorAdaScriptRuntimePluginResolver.resolve(project.runtime.plugins)
        let allowed: Set<String> = ["core2d", "sprite", "light2d", "mesh2d", "tilemap", "physics2d", "audio", "upscale", "core3d", "model3d", "physics3d", "multiplayer"]
        guard plugins.pluginIDs.allSatisfy({ allowed.contains($0.rawValue) }),
              !files.contains(where: { $0.path.hasPrefix("Sources/") && (String(data: $0.data, encoding: .utf8) ?? "").contains("@view") }) else {
            throw EditorCommunityPackageManifest.Failure.incompatibleProject
        }
        let advanced = plugins.pluginIDs.contains(where: { ["core3d", "model3d", "physics3d", "multiplayer"].contains($0.rawValue) })
            || files.contains(where: { ["glb", "gltf"].contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased())
                || ($0.path.hasPrefix("Sources/") && (String(data: $0.data, encoding: .utf8) ?? "").contains("@scriptable")) })
        let descriptor: EditorCloudValue = ["formatVersion": 1, "runtime": "adascript", "apiVersion": .integer(advanced ? 2 : 1)]
        files.append(.init(path: "ada-game.json", data: try encoder.encode(descriptor)))
        let manifest = EditorCommunityPackageManifest(
            formatVersion: 1,
            runtime: "adascript",
            apiVersion: advanced ? 2 : 1,
            files: files.map { .init(path: $0.path, size: $0.data.count, sha256: EditorCommunityPackageManifest.digest($0.data)) }
        )
        try manifest.validate()
        if let scene = portable.runtime.entry.scene {
            guard scene.hasPrefix("Assets/"), files.contains(where: { $0.path == scene }) else {
                throw EditorPublicationError("The entry scene must be packaged under Assets.")
            }
        }
        try EditorCommunityModelAssets.validate(in: projectURL)
        return EditorPublicationZIP.encode(files.sorted { $0.path < $1.path })
    }
}

/// Small portable ZIP writer using stored entries, bounded by the 64 MB player limit.
enum EditorPublicationZIP {
    static func encode(_ files: [PlayerProjectSnapshot.File]) -> Data {
        var archive = Data(), directory = Data()
        for file in files {
            let name = Data(file.path.utf8), size = UInt32(file.data.count), offset = UInt32(archive.count)
            let crc = file.data.reduce(UInt32.max) { checksum, byte in
                var value = checksum ^ UInt32(byte)
                for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xedb88320 : 0) }
                return value
            } ^ UInt32.max
            archive.zipInteger(UInt32(0x04034b50))
            for value in [UInt16(20), 0, 0, 0, 33] { archive.zipInteger(value) }
            for value in [crc, size, size] { archive.zipInteger(value) }
            archive.zipInteger(UInt16(name.count)); archive.zipInteger(UInt16(0))
            archive.append(name); archive.append(file.data)
            directory.zipInteger(UInt32(0x02014b50))
            for value in [UInt16(20), 20, 0, 0, 0, 33] { directory.zipInteger(value) }
            for value in [crc, size, size] { directory.zipInteger(value) }
            for value in [UInt16(name.count), 0, 0, 0, 0] { directory.zipInteger(value) }
            directory.zipInteger(UInt32(0)); directory.zipInteger(offset); directory.append(name)
        }
        let offset = UInt32(archive.count)
        archive.append(directory)
        archive.zipInteger(UInt32(0x06054b50))
        for value in [UInt16(0), 0, UInt16(files.count), UInt16(files.count)] { archive.zipInteger(value) }
        archive.zipInteger(UInt32(directory.count)); archive.zipInteger(offset); archive.zipInteger(UInt16(0))
        return archive
    }
}

private extension Data {
    mutating func zipInteger<T: FixedWidthInteger>(_ value: T) {
        for index in 0..<MemoryLayout<T>.size { append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
    }
}

struct EditorPublicationError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
