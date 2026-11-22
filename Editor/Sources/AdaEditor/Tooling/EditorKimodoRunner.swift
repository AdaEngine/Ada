#if os(Windows)
import AdaEngine
import Foundation

actor EditorKimodoRunner {
    static let shared = EditorKimodoRunner()

    struct Request: Encodable, Sendable {
        let protocolVersion = 1
        let jobID: String
        let prompt: String
        let duration: Double

        func encodedData() throws -> Data {
            let data = try JSONEncoder().encode(self)
            guard data.count <= 8_192 else {
                throw EditorKimodoError.descriptionTooLong
            }
            return data
        }
    }

    private struct Event: Decodable {
        let protocolVersion: Int
        let jobID: UUID?
        let status: String
    }

    private struct Release: Decodable { let version: String }

    private let runner = EditorProcessRunner()
    private let files = FileManager.default
    private let root: URL
    private let applicationDirectory: URL
    private var running = false

    init(root: URL? = nil, applicationDirectory: URL? = nil) {
        let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        self.root = root ?? local.appendingPathComponent("AdaStudio/Tools/Kimodo", isDirectory: true)
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        self.applicationDirectory = applicationDirectory ?? executable.deletingLastPathComponent()
    }

    func inspect(_ archive: URL) throws -> EditorKimodoManifest {
        try verify(EditorKimodoManifest.open(archive))
    }

    func install(_ archive: URL) throws -> String {
        let contents = try EditorKimodoManifest.open(archive)
        let manifest = try verify(contents)
        guard let manifestBytes = contents["manifest.json"] else { throw EditorKimodoError.invalidPackage }
        let name = manifest.version + "-" + EditorKimodoManifest.digest(manifestBytes)
        let versions = root.appendingPathComponent("versions", isDirectory: true)
        let destination = versions.appendingPathComponent(name, isDirectory: true)
        try files.createDirectory(at: versions, withIntermediateDirectories: true)
        if files.fileExists(atPath: destination.path) {
            _ = try self.verify(self.installedFiles(destination))
        } else {
            let stage = versions.appendingPathComponent("stage-" + UUID().uuidString, isDirectory: true)
            try files.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? files.removeItem(at: stage) }
            for (filename, bytes) in contents { try bytes.write(to: stage.appendingPathComponent(filename)) }
            try files.moveItem(at: stage, to: destination)
        }
        try Data(name.utf8).write(to: root.appendingPathComponent("active"), options: .atomic)
        return manifest.version
    }

    func generate(prompt: String, duration: Double, onGeneration: @Sendable @escaping () async -> Void) async throws -> SOMAHumanoidMotion {
        guard !running else { throw EditorKimodoError.generationFailed }
        running = true
        defer { running = false }
        let package = try activeDirectory()
        _ = try verify(installedFiles(package))
        let id = UUID()
        let data = try Request(jobID: id.uuidString.lowercased(), prompt: prompt, duration: duration).encodedData()
        let directory = root.appendingPathComponent("jobs/" + id.uuidString.lowercased(), isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let request = directory.appendingPathComponent("request.json")
        try data.write(to: request, options: .atomic)
        let launch = package.appendingPathComponent("launch.sh")
        let launchPath = try await linuxPath(launch)
        let requestPath = try await linuxPath(request)
        let gpu = await runner.run(command(["/usr/lib/wsl/lib/nvidia-smi", "--query-gpu=name", "--format=csv,noheader"], in: directory))
        guard gpu.succeeded else { throw EditorKimodoError.cudaUnavailable }
        try Task.checkCancellation()

        let cancellationFile = directory.appendingPathComponent("cancelled")
        let command = command(["/bin/bash", launchPath, requestPath], in: directory)
        let work = Task {
            await runner.run(command) { event in
                if event.stream == .standardOutput, event.text.contains("\"generating\"") { await onGeneration() }
            }
        }
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            try? Data().write(to: cancellationFile, options: .atomic)
        }
        try Task.checkCancellation()
        let events = result.standardOutput.split(whereSeparator: \.isNewline).compactMap {
            try? JSONDecoder().decode(Event.self, from: Data($0.utf8))
        }
        guard let event = events.last, event.protocolVersion == 1, event.jobID == id else { throw EditorKimodoError.generationFailed }
        if event.status == "modelAccessRequired" { throw EditorKimodoError.modelAccessRequired }
        guard result.succeeded, event.status == "completed" else { throw EditorKimodoError.generationFailed }
        let output = try read(directory.appendingPathComponent("motion.json"), limit: 3 * 1024 * 1024)
        let motion = try JSONDecoder().decode(SOMAHumanoidMotion.self, from: output)
        guard motion.protocolVersion == 1, motion.jobID == id else { throw EditorKimodoError.invalidResult }
        return motion
    }

    private func activeDirectory() throws -> URL {
        let url = root.appendingPathComponent("active")
        guard let data = try? read(url, limit: 96), let name = String(data: data, encoding: .ascii),
              name.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+-[0-9a-f]{64}/) != nil else { throw EditorKimodoError.notInstalled }
        return root.appendingPathComponent("versions/" + name, isDirectory: true)
    }

    private func installedFiles(_ directory: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        var remaining = EditorKimodoManifest.maximumBytes
        for name in EditorKimodoManifest.payload.union(EditorKimodoManifest.metadata) {
            let data = try read(directory.appendingPathComponent(name), limit: remaining)
            remaining -= data.count
            files[name] = data
        }
        return files
    }

    private func read(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: limit + 1), data.count <= limit else { throw EditorKimodoError.invalidPackage }
        return data
    }

    private func verify(_ contents: [String: Data]) throws -> EditorKimodoManifest {
        let release = try read(applicationDirectory.appendingPathComponent("release.json"), limit: 8192)
        let version = try JSONDecoder().decode(Release.self, from: release).version
        guard let trust = try? read(applicationDirectory.appendingPathComponent("kimodo-keys.json"), limit: 4096) else {
            throw EditorKimodoError.incompatiblePackage
        }
        let keys = try JSONDecoder().decode([Data].self, from: trust)
        return try EditorKimodoManifest.verify(contents, keys: keys, studioVersion: version)
    }

    private func linuxPath(_ url: URL) async throws -> String {
        let result = await runner.run(command(["wslpath", "-a", "-u", url.path], in: root))
        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, path.hasPrefix("/"), !path.contains(where: \.isNewline) else { throw EditorKimodoError.wslUnavailable }
        return path
    }

    private func command(_ arguments: [String], in directory: URL) -> EditorProcessCommand {
        EditorProcessCommand(
            executablePath: "wsl.exe",
            arguments: ["--distribution", "Ubuntu", "--exec"] + arguments,
            workingDirectory: directory,
            displayName: "Kimodo"
        )
    }
}
#endif
