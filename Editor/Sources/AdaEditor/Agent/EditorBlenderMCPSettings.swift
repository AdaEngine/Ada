#if os(Windows)
import Crypto
import Foundation
import Observation
import WinSDK

/// The Blender preset is configured explicitly in Studio user settings.
@Observable @MainActor
final class EditorBlenderMCPSettings {
    static let shared = EditorBlenderMCPSettings(defaults: .standard)
    var executablePath: String
    private(set) var connecting = false
    private(set) var connected = false
    private(set) var isEnabled = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var connection: Connection?
    @ObservationIgnored private var pendingServer: EditorWindowsLocalMCP?
    @ObservationIgnored private var approvedIdentity: Data?
    @ObservationIgnored private var attempt = Foundation.UUID()
    @ObservationIgnored private var selection = Foundation.UUID()

    private struct Connection: Sendable {
        let id = Foundation.UUID()
        let server: EditorWindowsLocalMCP
        let identity: Data
        let schema: EditorCloudValue
        let directory: URL
    }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        executablePath = defaults?.string(forKey: "AdaEditor.blenderMCP.executable") ?? ""
        approvedIdentity = defaults?.data(forKey: "AdaEditor.blenderMCP.enabledIdentity")
    }

    func connect() async {
        guard !connecting, connection == nil else {
            return
        }
        connecting = true
        errorMessage = nil
        let attempt = self.attempt
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaStudio-Blender-\(Foundation.UUID().uuidString)", isDirectory: true)
        var started: EditorWindowsLocalMCP?
        defer {
            if self.attempt == attempt {
                connecting = false
                pendingServer = nil
            }
        }
        do {
            let path = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard EditorHostTools.isAbsolutePath(path), url.pathExtension.lowercased() == "exe",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw EditorWindowsLocalMCP.Failure.launch
            }
            let digest = try await Self.executableDigest(url)
            try Task.checkCancellation()
            guard self.attempt == attempt else { throw CancellationError() }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let server = try EditorWindowsLocalMCP(executable: url, arguments: ["--host", "127.0.0.1"], directory: directory)
            started = server
            pendingServer = server
            try await server.initialize()
            let schema = try Self.blenderSchema(await server.tools())
            try Task.checkCancellation()
            guard self.attempt == attempt else { throw CancellationError() }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let identity = try encoder.encode([
                "path": .string(url.path), "digest": .string(digest), "schema": schema
            ] as [String: EditorCloudValue])
            let candidate = Connection(server: server, identity: identity, schema: schema, directory: directory)
            connection = candidate
            defaults?.set(path, forKey: "AdaEditor.blenderMCP.executable")
            connected = true
            isEnabled = identity == approvedIdentity
            Task { [weak self] in
                await server.waitForClose()
                guard let self, self.connection?.id == candidate.id else {
                    return
                }
                await self.disconnect()
                self.errorMessage = EditorWindowsLocalMCP.Failure.closed.localizedDescription
            }
        } catch {
            await started?.disconnect()
            Self.removeEmptyDirectory(directory)
            if self.attempt == attempt, !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func disconnect() async {
        attempt = Foundation.UUID()
        let previous = connection
        let starting = pendingServer
        connection = nil
        pendingServer = nil
        connecting = false
        connected = false
        isEnabled = false
        errorMessage = nil
        await previous?.server.disconnect()
        await starting?.disconnect()
        if let previous { Self.removeEmptyDirectory(previous.directory) }
    }

    func enable(_ enabled: Bool) {
        guard let connection else {
            return
        }
        if enabled != isEnabled { selection = Foundation.UUID() }
        isEnabled = enabled
        approvedIdentity = enabled ? connection.identity : nil
        defaults?.set(approvedIdentity, forKey: "AdaEditor.blenderMCP.enabledIdentity")
    }

    @concurrent nonisolated private static func executableDigest(_ url: URL) async throws -> String {
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var digest = SHA256()
            while let data = try file.read(upToCount: 256 * 1_024), !data.isEmpty {
                try Task.checkCancellation()
                digest.update(data: data)
            }
            return Data(digest.finalize()).base64EncodedString()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EditorWindowsLocalMCP.Failure.launch
        }
    }

    nonisolated private static func blenderSchema(_ tools: [EditorCloudValue]) throws -> EditorCloudValue {
        let matches = tools.filter { $0["name"].string == EditorBlenderMCPExport.remoteTool }
        guard matches.count == 1, let schema = matches.first?["inputSchema"], schema["type"].string == "object",
              schema["properties"]["code"]["type"].string == "string", schema["required"].array == ["code"],
              schema["$ref"] == .null else { throw EditorWindowsLocalMCP.Failure.unsupported }
        let properties = schema["properties"].object
        guard Set(properties.keys).isSubset(of: ["code", "user_prompt"]), properties["user_prompt"] == nil || properties["user_prompt"]?["type"].string == "string"
        else { throw EditorWindowsLocalMCP.Failure.unsupported }
        return schema
    }

    private static func removeEmptyDirectory(_ directory: URL) {
        // The subprocess owns its working directory contents. Delete only an empty directory.
        _ = RemoveDirectoryW(Array(directory.path.utf16) + [0])
    }

    func tools(
        projectURL: URL,
        isCurrentProject: @escaping @Sendable () async -> Bool,
        mayInvoke: @escaping @Sendable () async -> Bool = { true }
    ) -> [EditorCloudAgentTool] {
        let root = projectURL.resolvingSymlinksInPath().standardizedFileURL
        let connection = isEnabled ? self.connection : nil
        guard connection != nil || EditorBlenderSceneJob.hasExports(in: root) else {
            return []
        }
        let selection = self.selection
        let authorized: @Sendable () async -> Bool = {
            guard let connection, await isCurrentProject() else {
                return false
            }
            return await self.isAuthorized(connection.id, selection: selection)
        }
        let authorizedExport: @Sendable () async -> Bool = {
            guard await authorized() else { return false }
            return await mayInvoke()
        }
        let definitions = (connection == nil ? [] : [EditorBlenderMCPExport.toolDefinition]) + EditorBlenderSceneAction.definitions
        return [
            .init(name: "editor_external_list", definition: [:], readOnly: true, invoke: { _ in
                guard await isCurrentProject() else { throw EditorBlenderMCPExport.Failure.authorization }
                let available = await Self.available(definitions, canExport: authorized)
                let items: [EditorCloudValue] = available.map { ["tool": $0["tool"], "description": $0["description"]] }
                return try EditorAgentToolEncoding.string(JSONEncoder().encode(["tools": items]))
            }),
            .init(name: "editor_external_describe", definition: [:], readOnly: true, invoke: { input in
                guard await isCurrentProject() else { throw EditorBlenderMCPExport.Failure.authorization }
                let available = await Self.available(definitions, canExport: authorized)
                guard let definition = available.first(where: { $0["tool"] == input["tool"] }) else { throw EditorBlenderMCPExport.Failure.authorization }
                return try EditorAgentToolEncoding.string(JSONEncoder().encode(definition))
            }),
            .init(
                name: "editor_external_invoke",
                definition: [:],
                readOnly: false,
                invoke: { input in
                    guard await isCurrentProject(), await mayInvoke() else { throw EditorBlenderMCPExport.Failure.authorization }
                    if input["tool"].string != EditorBlenderMCPExport.alias {
                        let result = try await EditorBlenderSceneAction(input).run(project: root)
                        return try EditorAgentToolEncoding.string(JSONEncoder().encode(result))
                    }
                    let recipe = try EditorBlenderMCPExport.recipe(from: input)
                    guard let connection, await authorizedExport() else { throw EditorBlenderMCPExport.Failure.authorization }
                    let revision = await connection.server.toolListRevision
                    let discovered = try await connection.server.tools()
                    guard let schema = try? Self.blenderSchema(discovered), schema == connection.schema else {
                        await self.invalidate(connection.id)
                        throw EditorBlenderMCPExport.Failure.authorization
                    }
                    let path = try await EditorBlenderMCPExport.export(
                        recipe,
                        in: root,
                        using: connection.server,
                        expectedRevision: revision,
                        isAuthorized: authorizedExport
                    )
                    let job = root.appendingPathComponent(path).deletingLastPathComponent().lastPathComponent
                    return try EditorAgentToolEncoding.string(JSONEncoder().encode(["artifact": path, "job": job, "stage": "exported"]))
                },
                validate: { input in
                    if input["tool"].string == EditorBlenderMCPExport.alias {
                        _ = try EditorBlenderMCPExport.recipe(from: input)
                    } else {
                        _ = try EditorBlenderSceneAction(input)
                    }
                },
                approvalDetails: { try EditorLocalMCPTool.inputDetails($0["input"]) }
            )
        ]
    }

    nonisolated private static func available(_ tools: [EditorCloudValue], canExport: @Sendable () async -> Bool) async -> [EditorCloudValue] {
        if await canExport() { return tools }
        return tools.filter { $0["tool"].string != EditorBlenderMCPExport.alias }
    }

    private func isAuthorized(_ id: Foundation.UUID, selection: Foundation.UUID) -> Bool {
        isEnabled && connection?.id == id && selection == self.selection
    }

    private func invalidate(_ id: Foundation.UUID) async {
        guard connection?.id == id else {
            return
        }
        enable(false)
        await disconnect()
        errorMessage = EditorBlenderMCPExport.Failure.authorization.localizedDescription
    }
}
#endif
