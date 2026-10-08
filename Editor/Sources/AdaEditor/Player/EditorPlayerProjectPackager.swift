import AdaEngine
import AdaPlayerConnect
import Foundation

enum EditorPlayerProjectPackager {
    /// Resolved library sources travel with the project; no package manager runs on the device.
    @concurrent
    static func prepare(at root: URL) async throws -> PlayerProjectSnapshot {
        let project = try ProjectSystem.loadProject(at: root)
        try ProjectSystem.validateRunCompatibility(of: project, at: root, destination: .iPadOS)
        let artifact = try EditorAdaScriptProjectBuilder().prepare(project: project, at: root)
        var portable = project
        portable.paths.sources = "PlayerSources"
        portable.ai = AdaProjectAI()
        portable.editor = AdaProjectEditor()
        portable.run = AdaProjectRun(destination: .iPadOS)
        portable.paths.build = nil
        portable.paths.generated = nil
        portable.paths.run = AdaProjectRunPaths()
        var files = [PlayerProjectSnapshot.File(path: ".ada/project.json", data: try JSONEncoder().encode(portable))]
        for (index, source) in artifact.sources.enumerated() {
            files.append(.init(path: "PlayerSources/\(index).ada", data: Data(source.source.utf8)))
        }
        let manager = FileManager.default
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var seen = Set(files.map(\.path))
        var size = files.reduce(0) { $0 + $1.data.count }
        func append(_ url: URL) throws {
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            guard canonical.path.hasPrefix(canonicalRoot.path + "/") else {
                throw PlayerConnectError.invalid("Preview resources must be inside the project: \(url.lastPathComponent)")
            }
            let path = String(canonical.path.dropFirst(canonicalRoot.path.count + 1))
            try PlayerProjectSnapshot.validatePath(path)
            let attributes = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard attributes.isSymbolicLink != true else {
                throw PlayerConnectError.invalid("Preview does not support symbolic links: \(path)")
            }
            guard attributes.isRegularFile == true, !seen.contains(path) else {
                return
            }
            size += attributes.fileSize ?? 0
            guard size <= PlayerProjectSnapshot.maximumBytes, files.count < PlayerProjectSnapshot.maximumFiles else {
                throw PlayerConnectError.invalid("Preview limit: 64 MB and 4096 files.")
            }
            let data = try Data(contentsOf: canonical)
            seen.insert(path)
            files.append(.init(path: path, data: data))
        }
        let roots = [project.paths.assets ?? "Assets"] + project.paths.resourceRoots
        for path in roots {
            try PlayerProjectSnapshot.validatePath(path)
            let directory = canonicalRoot.appendingPathComponent(path)
            guard manager.fileExists(atPath: directory.path) else {
                continue
            }
            guard
                directory.resolvingSymlinksInPath().path.hasPrefix(canonicalRoot.path + "/"),
                (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true
            else {
                throw PlayerConnectError.invalid("Preview resource folder must be inside the project.")
            }
            guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
                throw PlayerConnectError.invalid("Cannot read resource folder: \(path)")
            }
            while let file = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                try append(file)
            }
        }
        if let scene = project.runtime.entry.scene {
            try PlayerProjectSnapshot.validatePath(scene)
            try append(canonicalRoot.appendingPathComponent(scene))
        }
        let snapshot = PlayerProjectSnapshot(files: files)
        try snapshot.validate()
        return snapshot
    }
}
