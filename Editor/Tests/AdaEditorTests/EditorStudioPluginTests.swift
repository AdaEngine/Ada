import Foundation
import Testing

@testable import AdaEditor

@Suite("Studio plugin packages")
struct EditorStudioPluginTests {
    @Test func capabilityChangesInvalidateTheDiscoveredRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Tools/example", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
            @tool(id: "studio.example", name: "Example", version: "1.0.0", api: 1, platforms: ["macos", "windows"], permissions: [])
            class Example { func activate(editor) {} }
            """.write(to: folder.appendingPathComponent("Example.ada"), atomically: true, encoding: .utf8)
        let manifest = folder.appendingPathComponent("plugin.json")
        try #"{"version":1,"id":"studio.example","actions":[]}"#.write(to: manifest, atomically: true, encoding: .utf8)
        let before = try #require(EditorStudioToolDiscovery.discover(at: root).first)
        try #"{"id":"studio.example","version":1,"actions":[]}"#.write(to: manifest, atomically: true, encoding: .utf8)
        let after = try #require(EditorStudioToolDiscovery.discover(at: root).first)
        #expect(before.signature != after.signature)
    }
}
