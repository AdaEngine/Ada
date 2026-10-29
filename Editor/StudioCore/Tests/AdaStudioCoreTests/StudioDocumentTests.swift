import Foundation
import Testing
@testable import AdaStudioCore

@Suite("Studio portable projects")
struct StudioDocumentTests {
    @Test func fastJSONValuesPreserveCodableSemantics() throws {
        for json in [
            "null", "true", "false", "0", "1", "-1", "1.0", "-0.0", "1.5", "1e30",
            "18446744073709551615", "-9223372036854775808",
            "[null, true, false, 1, 1.25, \"true\", {\"vector\": [0, -1, 2.5]}]"
        ] {
            let data = Data(json.utf8)
            #expect(try StudioValue.decode(data) == JSONDecoder().decode(StudioValue.self, from: data))
        }
    }

    @Test func agentProjectSourcePaths() {
        for path in ["AGENTS.md", "DESIGN.md", "PLAN.md", "PROGRESS.md", "Docs/Context.txt", "Tests/Rules.ada", ".ada/skills/my-game/SKILL.md", "Assets/Generated/Tree.vox"] {
            #expect(StudioSnapshot.validPath(path))
        }
        for path in [".ada/skills/my-game/run.sh", ".ada/skills/../SKILL.md", "Docs/run.exe", ".ada/credentials.md"] {
            #expect(!StudioSnapshot.validPath(path))
        }
    }
    @Test func standardZIPChecksum() { #expect(StudioArchive.crc32(Data("123456789".utf8)) == 0xcbf43926) }
    @Test func importsDeflatedZIP() throws {
        // Produced by Python zipfile, independently of the Studio ZIP writer.
        let encoded = "UEsDBBQAAAAIANZ0UV2RnUWXEwAAAPcBAAAQAAAAU291cmNlcy9UZXN0LmFkYdPXV3BMSQxOLsosKOEaZY0UFgBQSwECFAAUAAAACADWdFFdkZ1FlxMAAAD3AQAAEAAAAAAAAAAAAAAAgAEAAAAAU291cmNlcy9UZXN0LmFkYVBLBQYAAAAAAQABAD4AAABBAAAAAAA="
        let archive = try #require(Data(base64Encoded: encoded))
        let files = try StudioArchive.decode(archive)
        #expect(files.map(\.path) == ["Sources/Test.ada"])
        #expect(files.first?.text == "// " + String(repeating: "AdaScript\n", count: 50))
    }
    @Test(arguments: StudioTemplate.allCases)
    func archiveRoundTrip(_ template: StudioTemplate) throws {
        let project = try template.makeProject()
        let archive = try StudioArchive.encode(project.exportFiles())
        let files = try StudioArchive.decode(archive)
        let imported = try StudioSnapshot(title: project.title, files: files).importedCopy()
        try imported.validate()
        #expect(imported.sources == project.sources)
        #expect(imported.metadata["project"]["id"] != project.metadata["project"]["id"])
        #expect(imported.file(project.scenePath)?.data == project.file(project.scenePath)?.data)
    }

    @Test @MainActor
    func atomicEditsUndoAndScenePreservation() throws {
        let document = try StudioDocument(snapshot: StudioTemplate.game3D.makeProject())
        var scene = try StudioScene(data: #require(document.snapshot.file(document.snapshot.scenePath)).data)
        let player = try #require(scene.entities.first(where: { $0["name"].string == "Player" })?["id"].string)
        let before = document.snapshot
        try scene.set(entity: player, component: "AdaTransform.Transform", field: "position", value: .array([.int(2), .int(3), .int(4)]))
        try document.write(document.snapshot.scenePath, data: scene.encoded())
        #expect(document.canUndo)
        document.undo()
        #expect(document.snapshot == before)
        document.redo()
        #expect(document.snapshot != before)
        let valid = document.snapshot
        #expect(throws: StudioError.self) { try document.delete(".ada/project.json") }
        #expect(document.snapshot == valid)
    }

    @Test
    func archiveRejectsCorruptionAndUnsafePaths() throws {
        let project = try StudioTemplate.game2D.makeProject()
        var archive = try StudioArchive.encode(project.exportFiles())
        archive[60] ^= 0xff
        #expect(throws: StudioError.self) { _ = try StudioArchive.decode(archive) }
        for path in ["../key", "Assets/../../secret", "/etc/passwd", "Assets\\secret", ".ada/credentials.json", "Assets/a.png/../b.png"] {
            #expect(!StudioSnapshot.validPath(path))
        }
        #expect(throws: StudioError.self) { _ = try StudioArchive.decode(Data(repeating: 0, count: 30)) }
    }

    @Test
    func credentialsAndHostSettingsDoNotExport() throws {
        var project = try StudioTemplate.game2D.makeProject()
        var metadata = project.metadata
        metadata["ai"] = .object(["apiKey": .string("SECRET")])
        metadata["editor"] = .object(["machinePath": .string("SECRET")])
        let index = try #require(project.files.firstIndex(where: { $0.path == ".ada/project.json" }))
        project.files[index].data = try metadata.encoded()
        let archive = try StudioArchive.encode(project.exportFiles())
        #expect(!String(decoding: archive, as: UTF8.self).contains("SECRET"))
    }

    @Test
    func malformedAndDuplicateProjectsAreRejected() throws {
        var project = try StudioTemplate.game2D.makeProject()
        project.files.append(project.files[0])
        #expect(throws: StudioError.self) { try project.validate() }
        var scene = StudioScene(value: .object(["entities": .array([])]))
        #expect(throws: StudioError.self) { _ = try scene.add(name: "Cycle", components: [:], parent: "missing") }
    }
}
