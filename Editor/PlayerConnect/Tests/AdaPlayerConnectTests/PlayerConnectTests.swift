import Foundation
import Network
import Testing
@testable import AdaPlayerConnect

@Suite("AdaPlayer protocol and deployment", .serialized)
struct PlayerConnectTests {
    private func snapshot(_ value: String = "first") -> PlayerProjectSnapshot {
        PlayerProjectSnapshot(files: [
            .init(path: ".ada/project.json", data: Data("{}".utf8)),
            .init(path: "Assets/hello.txt", data: Data(value.utf8))
        ])
    }

    @Test func installsFreshProjectsWithoutStaleFiles() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = try snapshot().install(in: parent)
        let second = try snapshot("second").install(in: parent)
        #expect(first != second)
        #expect(try String(contentsOf: first.appendingPathComponent("Assets/hello.txt"), encoding: .utf8) == "first")
        #expect(try String(contentsOf: second.appendingPathComponent("Assets/hello.txt"), encoding: .utf8) == "second")
    }

    @Test(arguments: ["../escape", "/tmp/escape", "a/../../x", "a//b", "a/./b", "a\\b", "a:b", "a\0b"])
    func rejectsInvalidPaths(_ path: String) {
        #expect(throws: PlayerConnectError.self) { try PlayerProjectSnapshot.validatePath(path) }
    }

    @Test(arguments: ["Assets/HELLO.txt", "Assets/hello.txt/child"])
    func rejectsFilesystemAliases(_ path: String) {
        let project = PlayerProjectSnapshot(files: snapshot().files + [.init(path: path, data: Data())])
        #expect(throws: PlayerConnectError.self) { try project.validate() }
    }

    @Test func rejectsMissingMetadataAndOversizedProjects() {
        #expect(throws: PlayerConnectError.self) { try PlayerProjectSnapshot(files: []).validate() }
        let large = PlayerProjectSnapshot(files: snapshot().files + [.init(path: "big", data: Data(count: PlayerProjectSnapshot.maximumBytes))])
        #expect(throws: PlayerConnectError.self) { try large.validate() }
    }

    @Test @MainActor func realConnectionPairsDeploysRestartsStopsAndDisconnects() async throws {
        let host = PlayerHost()
        var deployments: [PlayerProjectSnapshot] = []
        var stops = 0
        host.onDeploy = { deployments.append($0) }
        host.onStop = { stops += 1 }
        try host.start(name: "AdaPlayer tests")
        defer { host.shutdown() }
        let port = try await listeningPort(host)
        let client = PlayerConnection(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        client.start()
        let deadline = Task { try? await Task.sleep(for: .seconds(10)); if !Task.isCancelled { client.cancel() } }
        defer { deadline.cancel(); client.cancel() }
        try await client.send(PlayerMessage(.pair, text: host.code))
        #expect(try await client.receive().kind == .paired)
        try await client.send(PlayerMessage(.deploy, project: snapshot()))
        #expect(try await client.receive().text == "running")
        try await client.send(PlayerMessage(.deploy, project: snapshot("second")))
        #expect(try await client.receive().text == "running")
        #expect(deployments.count == 2)
        try await host.send(PlayerMessage(.log, text: "game log"))
        #expect(try await client.receive().text == "game log")
        try await client.send(PlayerMessage(.stop))
        #expect(try await client.receive().text == "stopped")
        #expect(stops == 1)
        client.cancel()
        for _ in 0..<100 where host.isPaired { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!host.isPaired)
        #expect(stops == 2)
    }

    @Test @MainActor func rejectsUnpairedDeploymentAndWrongCode() async throws {
        let host = PlayerHost()
        var deployed = false
        host.onDeploy = { _ in deployed = true }
        try host.start(name: "AdaPlayer authentication tests")
        defer { host.shutdown() }
        let port = try await listeningPort(host)
        for message in [PlayerMessage(.pair, text: "wrong"), PlayerMessage(.deploy, project: snapshot())] {
            let client = PlayerConnection(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
            client.start()
            let deadline = Task { try? await Task.sleep(for: .seconds(10)); if !Task.isCancelled { client.cancel() } }
            defer { deadline.cancel(); client.cancel() }
            try await client.send(message)
            #expect(try await client.receive().kind == .failure)
            #expect(!deployed)
            // Allow the server's failure response to finish before attempting a new session.
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    @Test @MainActor func failedDeploymentKeepsSessionUsable() async throws {
        let host = PlayerHost()
        var attempts = 0
        host.onDeploy = { _ in
            attempts += 1
            if attempts == 1 { throw PlayerConnectError.invalid("Invalid scene") }
        }
        try host.start(name: "AdaPlayer recovery tests")
        defer { host.shutdown() }
        let port = try await listeningPort(host)
        let client = PlayerConnection(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        client.start()
        let deadline = Task { try? await Task.sleep(for: .seconds(10)); if !Task.isCancelled { client.cancel() } }
        defer { deadline.cancel(); client.cancel() }
        try await client.send(PlayerMessage(.pair, text: host.code))
        #expect(try await client.receive().kind == .paired)
        try await client.send(PlayerMessage(.deploy, project: snapshot()))
        #expect(try await client.receive().text == "Invalid scene")
        try await client.send(PlayerMessage(.deploy, project: snapshot()))
        #expect(try await client.receive().text == "running")
        #expect(host.isPaired)
    }

    @MainActor private func listeningPort(_ host: PlayerHost) async throws -> NWEndpoint.Port {
        for _ in 0..<100 {
            if let value = host.port, let port = NWEndpoint.Port(rawValue: value) { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw PlayerConnectError.invalid("Listener failed to start: \(host.status)")
    }
}
