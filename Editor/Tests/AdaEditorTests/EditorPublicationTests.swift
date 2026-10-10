@testable import AdaEditor
import AdaEngine
import Foundation
import MCP
import Testing

@MainActor
@Suite("EditorPublication", .serialized)
struct EditorPublicationTests {
    @Test("Portable archive extracts with valid CRCs and preserves a playable project")
    func package() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await EditorCommunityProjectPackager.archive(projectURL: root)
        let zip = root.appendingPathComponent("game.zip")
        try archive.write(to: zip)
        let extracted = root.appendingPathComponent("extracted")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", zip.path, "-d", extracted.path]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let project = try ProjectSystem.loadProject(at: extracted)
        #expect(project.paths.sources == "Sources")
        #expect(project.paths.assets == "Assets")
        #expect(project.runtime.entry.scene == SceneDocumentFormat.defaultScenePath)
        #expect(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("Sources/0.ada").path))
        let descriptor = try JSONDecoder().decode(EditorCloudValue.self, from: Data(contentsOf: extracted.appendingPathComponent("ada-game.json")))
        #expect(descriptor["apiVersion"].int == 1)
        #expect(!FileManager.default.fileExists(atPath: extracted.appendingPathComponent(".ada/publication-draft.json").path))
        let service = EditorMobileAgentToolService(projectURL: extracted)
        #expect(service.build().ok)
        #expect(try await EditorCommunityProjectPackager.archive(projectURL: root) == archive)
    }

    @Test("Changed content reuses the same page; retries reuse media and the accepted submission")
    func submission() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "PublicationTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pageID = UUID().uuidString, mediaID = UUID().uuidString
        var creates = 0, patches = 0, images = 0, submissions = 0
        var lastRelease: EditorCloudValue = [:]
        func publisher() -> EditorProjectPublisher {
            EditorProjectPublisher(
                defaults: defaults,
                request: { path, method, body in
                    if method == "GET" {
                        #expect(path == "/game-releases?pageId=" + pageID)
                        return .array([lastRelease])
                    }
                    #expect(body?["title"].string == "Test game")
                    #expect(body?["cover"].string == mediaID)
                    if path == "/pages" { #expect(method == "POST"); creates += 1 } else {
                        #expect(path == "/pages/" + pageID); #expect(method == "PATCH"); patches += 1
                    }
                    return ["id": .string(pageID)]
                },
                uploadImage: { data in
                    #expect(data == Data([1, 2, 3])); images += 1
                    return ["id": .string(mediaID)]
                },
                submitArchive: { zip, page in
                    #expect(page == pageID)
                    let archiveBytes = try Data(contentsOf: zip)
                    #expect(archiveBytes.count > 100)
                    submissions += 1
                    lastRelease = ["id": .string(UUID().uuidString), "pageId": .string(pageID), "status": "pending", "number": .integer(Int64(submissions))]
                    return lastRelease
                }
            )
        }
        let image = root.appendingPathComponent("cover.png")
        try Data([1, 2, 3]).write(to: image)
        let draft = EditorPublicationDraft(title: "Test game", description: "A test app", cover: image, screenshots: [image])
        let first = try await publisher().submit(projectURL: root, draft: draft, owner: "owner", server: "https://cloud.example")
        let retry = try await publisher().submit(projectURL: root, draft: draft, owner: "owner", server: "https://cloud.example")
        #expect(first == retry)
        lastRelease["status"] = "rejected"
        let resubmission = try await publisher().submit(projectURL: root, draft: draft, owner: "owner", server: "https://cloud.example")
        #expect(resubmission["number"].int == 2)
        try "// New version".write(to: root.appendingPathComponent("Sources/Game.ada"), atomically: true, encoding: .utf8)
        let updated = try await publisher().submit(projectURL: root, draft: draft, owner: "owner", server: "https://cloud.example")
        #expect(updated["number"].int == 3)
        #expect(creates == 1 && patches == 3 && images == 1 && submissions == 3)
    }

    @Test("Projects without metadata IDs keep independent publication pages")
    func missingProjectIDs() async throws {
        let roots = [try fixture(), try fixture()]
        defer { for root in roots { try? FileManager.default.removeItem(at: root) } }
        let suite = "PublicationTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var createdPages: [String] = []
        let publisher = EditorProjectPublisher(
            defaults: defaults,
            request: { path, method, _ in
                #expect(path == "/pages")
                #expect(method == "POST")
                let pageID = UUID().uuidString
                createdPages.append(pageID)
                return ["id": .string(pageID)]
            },
            uploadImage: { _ in ["id": .string(UUID().uuidString)] },
            submitArchive: { _, pageID in
                ["id": .string(UUID().uuidString), "pageId": .string(pageID), "status": "pending"]
            }
        )
        for root in roots {
            var project = try ProjectSystem.loadProject(at: root)
            project.project.id = nil
            try ProjectSystem.saveProject(project, at: root)
            #expect(try ProjectSystem.loadProject(at: root).project.id == nil)
            let image = root.appendingPathComponent("cover.png")
            try Data([1, 2, 3]).write(to: image)
            let draft = EditorPublicationDraft(title: "Test game", description: "A test app", cover: image)
            _ = try await publisher.submit(projectURL: root, draft: draft, owner: "owner", server: "https://cloud.example")
        }
        #expect(createdPages.count == 2)
        #expect(Set(createdPages).count == 2)
    }

    @Test("Local failures do not create Cloud resources; agent rejects escaped image paths")
    func invalidInputs() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let publisher = EditorProjectPublisher(
            request: { _, _, _ in Issue.record("Unexpected request"); return [:] },
            uploadImage: { _ in Issue.record("Unexpected image upload"); return [:] },
            submitArchive: { _, _ in Issue.record("Unexpected submission"); return [:] }
        )
        await #expect(throws: EditorPublicationError.self) {
            try await publisher.submit(projectURL: root, draft: .init(title: ""), owner: "owner", server: "server")
        }
        let service = EditorMobileAgentToolService(projectURL: root)
        let result = await service.handle(name: "editor.community.submit", arguments: ["title": "App", "description": "App", "cover": "../outside.png"])
        #expect(!result.ok && result.payload.contains("project-relative"))
        #expect(EditorMobileAgentTools.tools().contains(where: { $0.name == "editor.community.submit" && $0.annotations?.readOnlyHint == false }))
        #expect(EditorAgentSkillStore.bundledSkills().contains(where: { $0.id == "ada-community-publish" }))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Publication-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets/Scenes"), withIntermediateDirectories: true)
        var project = ProjectSystem.defaultProject(projectName: "Publication", buildSystem: .adaScript)
        project.runtime.entry = .init(scene: SceneDocumentFormat.defaultScenePath)
        project.runtime.plugins.preset = .ui
        try ProjectSystem.saveProject(project, at: root)
        try "// Source".write(to: root.appendingPathComponent("Sources/Game.ada"), atomically: true, encoding: .utf8)
        var scene = EditorSceneModel.default(projectName: "Publication")
        scene.entities = []
        try scene.encodedYAML().write(to: root.appendingPathComponent(SceneDocumentFormat.defaultScenePath), atomically: true, encoding: .utf8)
        try EditorPublicationDraft(title: "Draft").save(at: root)
        return root
    }
}
