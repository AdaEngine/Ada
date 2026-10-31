#if canImport(Lore)
import Foundation
import Lore
import Testing

@testable import AdaEditor

@Suite("Lore server integration", .enabled(if: ProcessInfo.processInfo.environment["ADAEDITOR_LORE_TEST_SERVER"] != nil))
struct LoreServerIntegrationTests {
    @Test("Create, push and clone synthetic files through the configured test server", .timeLimit(.minutes(1)))
    func remoteRoundTrip() async throws {
        let server = try #require(ProcessInfo.processInfo.environment["ADAEDITOR_LORE_TEST_SERVER"])
        let parsed = try #require(URL(string: server))
        try #require(parsed.scheme == "lore" && parsed.host != nil)
        let name = "ada-studio-smoke-" + UUID().uuidString.lowercased()
        let remote = server.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + name
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        let original = root.appendingPathComponent("original", isDirectory: true)
        let cloned = root.appendingPathComponent("cloned", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloned, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = Library.setThreadLimit(8)
        try await Repository.create(at: original.path, name: remote, options: .init(identity: "ada-studio-smoke-test"))
        let text = "Ada Studio Lore server test\n"
        let binary = Data([0, 1, 2, 127, 255])
        try text.write(to: original.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        try binary.write(to: original.appendingPathComponent("asset.bin"))
        let service = LoreRepositoryService()
        for command in [GitCommandKind.stage(paths: ["hello.txt", "asset.bin"]), .commit(message: "Ada Studio server smoke test"), .push] {
            let result = await service.execute(command, projectURL: original)
            try #require(result.succeeded, "\(result.combinedOutput)")
        }
        try await Repository.clone(from: remote, to: cloned.path, options: .init(identity: "ada-studio-smoke-test"))
        #expect(try String(contentsOf: cloned.appendingPathComponent("hello.txt"), encoding: .utf8) == text)
        #expect(try Data(contentsOf: cloned.appendingPathComponent("asset.bin")) == binary)
        let history = try await service.history(projectURL: cloned, head: nil, offset: 0).get()
        #expect(history.commits.first?.subject == "Ada Studio server smoke test")
        print("Verified Lore test repository: \(remote)")
    }
}
#endif
