import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@Suite("External asset library")
struct EditorExternalAssetLibraryTests {
    private static let fab = "https://www.fab.com/listings/6d05505c-b139-4f89-bcf2-843a04ac1d9b"

    @Test func attachmentReplacementKeepsPreviousImportAndOriginal() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = EditorExternalAssetLibrary(project: root)
        let first = try await library.add(title: "Park bench", link: Self.fab + "?x=1")
        let duplicate = try await library.add(title: "Other name", link: Self.fab)
        #expect(first == duplicate)
        _ = try await library.add(title: "Bench props", link: "https://assetstore.unity.com/packages/3d/props/bench-1234")
        #expect(try await library.search("BENCH", store: .fab) == [first])
        #expect(try await library.search("bench", store: .unity).count == 1)

        let model = root.appendingPathComponent("bench.glb")
        let assets = root.appendingPathComponent("Assets", isDirectory: true)
        try modelBytes(width: 1).write(to: model)
        try await library.attach(model, listing: first.id, cover: false)
        let imported = try await library.modelImport(listing: first.id, assets: assets)
        #expect(try await library.modelImport(listing: first.id, assets: assets) == imported)
        try modelBytes(width: 2).write(to: model)
        try await library.attach(model, listing: first.id, cover: false)
        let replacement = try await library.modelImport(listing: first.id, assets: assets)
        #expect(imported != replacement)
        #expect(try Data(contentsOf: imported) != Data(contentsOf: replacement))
        try await library.removeModel(listing: first.id)

        let reopened = EditorExternalAssetLibrary(project: root)
        try await reopened.reconcile()
        let saved = try #require(await reopened.listing(id: first.id))
        #expect(await reopened.modelURL(for: saved) == nil)
        for url in [model, imported, replacement] {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func corruptedLibraryCannotProvideAnUntrustedStoreURL() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = EditorExternalAssetLibrary(project: root)
        _ = try await library.add(title: "Bench", link: Self.fab)
        let index = root.appendingPathComponent(".ada-external-assets/listings.json")
        let original = try String(contentsOf: index, encoding: .utf8)
        try original.replacingOccurrences(of: "www.fab.com", with: "unexpected.example").write(to: index, atomically: true, encoding: .utf8)
        await #expect(throws: EditorExternalAssetLibrary.Failure.self) { try await library.search() }
    }

    @Test @MainActor
    func activatesBothPluginKindsAndRevokesCapturedAITurns() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = EditorViewModel(project: .init(name: "Plugin fixture", path: root.path), autosaveDelay: .seconds(60))
        let defaults = try #require(UserDefaults(suiteName: "ExternalAssetLibrary-\(UUID())"))
        let host = EditorStudioToolHost(defaults: defaults)
        host.open(projectURL: root, editor: editor)
        defer { host.close() }
        let editorRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let payloads = [
            (editorRoot.deletingLastPathComponent().appendingPathComponent("Plugins/ExternalAssetLibrary"), "studio.external-asset-library"),
            (editorRoot.appendingPathComponent("Documentation/Examples/StudioTools/AIExample"), "studio.ai-example")
        ]
        let tools = root.appendingPathComponent("Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        for (folder, id) in payloads {
            try FileManager.default.copyItem(at: folder, to: tools.appendingPathComponent(id, isDirectory: true))
            host.reload()
            #expect(host.error == nil)
            host.enable(id)
            let permission = try #require(host.permissionRequest)
            host.approve(permission.id)
            #expect(host.enabledIDs.contains(id))
            host.setPluginAI(id, allowed: true)
        }
        let library = try #require(host.externalAssets)
        _ = try await library.add(title: "Park bench", link: Self.fab)
        let turn = EditorStudioPluginTurn(host: host, isCurrentWorkspace: { true })
        let tool = try #require(turn.tools().first { $0.name == "editor_plugins_invoke" })
        let example: EditorCloudValue = ["id": "studio.ai-example/status", "input": [:]]
        let status = try await json(tool, example)
        #expect(status["status"] == "ready")
        let result = try await json(tool, ["id": "studio.external-asset-library/search", "input": ["query": "bench", "store": "fab"]])
        let reference = try #require(result["assets"].array.first?["asset"].string)
        let detail: EditorCloudValue = ["id": "studio.external-asset-library/details", "input": ["asset": .string(reference)]]
        #expect(try await json(tool, detail)["name"] == "Park bench")
        let otherTurn = EditorStudioPluginTurn(host: host, isCurrentWorkspace: { true })
        let otherTool = try #require(otherTurn.tools().first { $0.name == "editor_plugins_invoke" })
        await #expect(throws: EditorStudioPluginManifest.Failure.self) { try await json(otherTool, detail) }
        host.setPluginAI("studio.ai-example", allowed: false)
        host.setPluginAI("studio.ai-example", allowed: true)
        await #expect(throws: EditorStudioPluginManifest.Failure.self) { try await json(tool, example) }
    }

    private func json(_ tool: EditorCloudAgentTool, _ input: EditorCloudValue) async throws -> EditorCloudValue {
        try await JSONDecoder().decode(EditorCloudValue.self, from: Data(tool.invoke(input).utf8))
    }

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExternalAssetLibrary-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func modelBytes(width: Float) throws -> Data {
        let mesh = ProceduralGeometry.box(width: width, height: 1, depth: 1)
        let model = ProceduralModel(materials: [.init(name: "Wood")], nodes: [.init(name: "Bench", mesh: mesh)])
        return try GLBWriter().encode(model)
    }
}
