#if os(macOS) || os(Windows)
#if os(macOS)
import AppKit
#endif
import Crypto
import Foundation
import Observation

/// User-owned connection preferences. Loading preferences never starts a process.
@Observable @MainActor
final class EditorLocalMCPSettings {
    static let shared: EditorLocalMCPSettings = {
        let settings = EditorLocalMCPSettings(fileURL: EditorAgentSettingsStore.directory.appendingPathComponent("local-mcp.json"))
        #if os(macOS)
        settings.terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
            [weak settings] _ in
            MainActor.assumeIsolated { settings?.terminateOwnedProcesses() }
        }
        #endif
        return settings
    }()

    struct Configuration: Codable, Identifiable, Sendable {
        let id: UUID
        var name = ""
        var executable = ""
        var arguments: [String] = []
        fileprivate var identity: String?
        fileprivate var approvals: [String: String] = [:]

        init(id: UUID = UUID()) { self.id = id }
    }

    struct Connection: Sendable {
        let id: UUID
        let server: EditorLocalMCPConnection
        let directory: URL
        let revision: UInt64
        let tools: [EditorLocalMCPTool]
        var selection = UUID()
    }

    private(set) var servers: [Configuration] = []
    private(set) var connections: [UUID: Connection] = [:]
    private(set) var connecting: Set<UUID> = []
    private(set) var errors: [UUID: String] = [:]
    private(set) var storageError: String?
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var attempts: [UUID: UUID] = [:]
    @ObservationIgnored private var starting: [UUID: EditorLocalMCPConnection] = [:]
    #if os(macOS)
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

    private func terminateOwnedProcesses() {
        for connection in connections.values { connection.server.terminateProcess() }
        for server in starting.values { server.terminateProcess() }
    }
    #endif

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            guard let bytes = try handle.read(upToCount: 2_000_001), bytes.count <= 2_000_000 else { throw Failure.settings }
            let decoded = try JSONDecoder().decode([Configuration].self, from: bytes)
            guard decoded.count <= 12, Set(decoded.map(\.id)).count == decoded.count else { throw Failure.settings }
            servers = decoded
        } catch { storageError = Failure.settings.localizedDescription }
    }

    func add() -> UUID? {
        guard servers.count < 12 else { return nil }
        let server = Configuration()
        servers.append(server)
        persist()
        return server.id
    }

    func edit(_ id: UUID, _ update: (inout Configuration) -> Void) {
        guard !connecting.contains(id), connections[id] == nil, let index = servers.firstIndex(where: { $0.id == id }) else { return }
        var updated = servers[index]
        update(&updated)
        guard updated.name.utf8.count <= 256, updated.executable.utf8.count <= 4_096, updated.arguments.count <= 32,
              updated.arguments.allSatisfy({ $0.utf8.count <= 4_096 }) else {
            errors[id] = Failure.configuration.localizedDescription
            return
        }
        if updated.executable != servers[index].executable || updated.arguments != servers[index].arguments {
            updated.identity = nil
            updated.approvals.removeAll()
        }
        servers[index] = updated
        errors[id] = nil
        persist()
    }

    func remove(_ id: UUID) {
        guard !connecting.contains(id), connections[id] == nil else { return }
        servers.removeAll { $0.id == id }
        errors[id] = nil
        persist()
    }

    func connect(_ id: UUID) async {
        guard !connecting.contains(id), connections[id] == nil, let config = servers.first(where: { $0.id == id }) else { return }
        connecting.insert(id)
        errors[id] = nil
        let attempt = UUID()
        attempts[id] = attempt
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaStudio-MCP-\(UUID().uuidString)", isDirectory: true)
        var launched: EditorLocalMCPConnection?
        defer { if attempts[id] == attempt { clearAttempt(id) } }
        do {
            let path = config.executable.trimmingCharacters(in: .whitespacesAndNewlines)
            let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            try validateConfiguration(config, executable: executable, path: path)
            let digest = try await Self.executableDigest(executable)
            try checkAttempt(id, attempt)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let server = try EditorLocalMCPConnection(executable: executable, arguments: config.arguments, directory: directory)
            launched = server
            starting[id] = server
            try await server.initialize()
            let revision = await server.toolListRevision
            let tools = try EditorLocalMCPTool.discover(await server.tools(expectedRevision: revision), server: id)
            try checkAttempt(id, attempt)
            let identity = try EditorLocalMCPTool.hash(EditorLocalMCPTool.encode([
                "path": .string(executable.path), "digest": .string(digest), "arguments": .array(config.arguments.map(EditorCloudValue.string)),
                "server": await server.serverIdentity
            ]))
            try checkAttempt(id, attempt)
            guard let index = servers.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
            servers[index].name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
            servers[index].identity = identity
            servers[index].approvals = config.identity == identity ? config.approvals.filter { name, fingerprint in
                tools.contains { $0.id == name && $0.fingerprint == fingerprint }
            } : [:]
            let connection = Connection(id: attempt, server: server, directory: directory, revision: revision, tools: tools)
            connections[id] = connection
            persist()
            observe(id, connection: connection)
        } catch {
            await launched?.disconnect()
            EditorLocalMCPConnection.removeEmptyDirectory(directory)
            if attempts[id] == attempt, !(error is CancellationError) {
                errors[id] = Self.message(error)
            }
        }
    }

    func disconnect(_ id: UUID) async {
        let connection = connections.removeValue(forKey: id)
        let pending = starting[id]
        #if os(macOS)
        connection?.server.terminateProcess()
        pending?.terminateProcess()
        #endif
        clearAttempt(id)
        errors[id] = nil
        await connection?.server.disconnect()
        await pending?.disconnect()
        if let connection { EditorLocalMCPConnection.removeEmptyDirectory(connection.directory) }
    }

    func isSelected(_ tool: EditorLocalMCPTool, server id: UUID) -> Bool {
        guard let fingerprint = tool.fingerprint else { return false }
        return servers.first { $0.id == id }?.approvals[tool.id] == fingerprint
    }

    func select(_ tool: EditorLocalMCPTool, server id: UUID, enabled: Bool) {
        guard let index = servers.firstIndex(where: { $0.id == id }), let fingerprint = tool.fingerprint,
              connections[id]?.tools.contains(where: { $0.id == tool.id && $0.fingerprint == fingerprint }) == true else { return }
        guard enabled != isSelected(tool, server: id) else { return }
        if enabled && servers.reduce(0, { $0 + $1.approvals.count }) >= 32 {
            errors[id] = Failure.toolLimit.localizedDescription
            return
        }
        servers[index].approvals[tool.id] = enabled ? fingerprint : nil
        connections[id]?.selection = UUID()
        errors[id] = nil
        persist()
    }

    private func validateConfiguration(_ config: Configuration, executable: URL, path: String) throws {
        let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(name.utf8.count), EditorLocalMCPTool.clean(name, limit: 80, multiline: false) == name,
              !servers.contains(where: { $0.id != config.id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame }),
              config.arguments.count <= 32, config.arguments.allSatisfy({ $0.utf8.count <= 4_096 && !$0.contains("\u{0}") }) else { throw Failure.configuration }
        #if os(Windows)
        guard executable.pathExtension.lowercased() == "exe" else { throw Failure.executable }
        #endif
        guard EditorHostTools.isAbsolutePath(path), path.utf8.count <= 4_096, !path.contains("\u{0}"),
              (try? executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure.executable }
    }

    private func checkAttempt(_ id: UUID, _ attempt: UUID) throws {
        try Task.checkCancellation()
        guard attempts[id] == attempt else { throw CancellationError() }
    }

    private func clearAttempt(_ id: UUID) {
        attempts[id] = nil
        starting[id] = nil
        connecting.remove(id)
    }

    private func observe(_ id: UUID, connection: Connection) {
        Task { [weak self] in
            for await revision in connection.server.toolChanges where revision != connection.revision {
                await self?.invalidate(id, connection: connection.id, reason: Failure.changed.localizedDescription)
                return
            }
            await self?.invalidate(id, connection: connection.id, reason: Failure.closed.localizedDescription)
        }
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(servers).write(to: fileURL, options: .atomic)
            #if os(macOS)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            #endif
            storageError = nil
        } catch { storageError = Failure.settings.localizedDescription }
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
            return EditorLocalMCPTool.digestString(digest.finalize())
        } catch is CancellationError { throw CancellationError() } catch { throw Failure.executable }
    }

    private static func message(_ error: any Error) -> String {
        if let failure = error as? Failure { return failure.localizedDescription }
        if error is EditorLocalMCPConnection.Failure { return Failure.connection.localizedDescription }
        return Failure.configuration.localizedDescription
    }

    func invalidate(_ id: UUID, connection: UUID, reason: String) async {
        guard connections[id]?.id == connection else { return }
        await disconnect(id)
        if connections[id] == nil, !connecting.contains(id) { errors[id] = reason }
    }

    enum Failure: LocalizedError {
        case settings, configuration, executable, connection, selection, changed, closed, toolLimit
        case transport(EditorLocalMCPConnection.Failure)

        var errorDescription: String? {
            switch self {
            case .settings: "Could not read or save local MCP settings."
            case .configuration: "Give the server a unique name and valid launch arguments."
            case .executable: "Enter the full path to an executable MCP server."
            case .connection: "Could not connect to the local MCP server. Check the command and its stdio tool support."
            case .selection: "This local MCP tool is no longer available. Review the connection and try again."
            case .changed: "The MCP tools changed. Reconnect and review the available tools."
            case .closed: "The local MCP server disconnected. Reconnect to use its tools."
            case .toolLimit: "Ada AI can use up to 32 selected local MCP tools."
            case .transport(.timeout), .transport(.closed): "The MCP call did not finish. The server may already have acted. Check before retrying."
            case .transport(.authorization), .transport(.unsupported): Failure.selection.localizedDescription
            case .transport(.busy): "The local MCP server is still finishing another request."
            case .transport: "The local MCP server could not complete the request."
            }
        }
    }
}
#endif
