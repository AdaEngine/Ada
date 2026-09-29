#if os(iOS)
import Foundation
import SloppyRuntime

@MainActor
enum MobileAdaScriptProjectService {

    static func projectURL(for id: UUID) throws -> URL {
        try projectsDirectory().appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func loadProjects() -> [MobileEditorProject] {
        (try? MobileEditorProjectStore(directory: projectsDirectory()).load()) ?? []
    }

    static func saveProjects(_ projects: [MobileEditorProject]) throws {
        try MobileEditorProjectStore(directory: projectsDirectory()).save(projects)
    }

    static func renameProject(id: UUID, to title: String) throws -> [MobileEditorProject] {
        try MobileEditorProjectStore(directory: projectsDirectory()).rename(id: id, to: title)
    }

    static func deleteProject(id: UUID) throws -> [MobileEditorProject] {
        try MobileEditorProjectStore(directory: projectsDirectory()).delete(id: id)
    }

    static func prepare(_ project: MobileEditorProject) throws -> URL {
        let directory = try projectURL(for: project.id)
        let sourceDirectory = directory.appendingPathComponent("Sources", isDirectory: true)
        let sceneDirectory = directory.appendingPathComponent("Assets/Scenes", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sceneDirectory, withIntermediateDirectories: true)

        let metadataURL = ProjectSystem.metadataURL(forProjectAt: directory)
        if !FileManager.default.fileExists(atPath: metadataURL.path) {
            var metadata = ProjectSystem.defaultProject(projectName: project.title, buildSystem: .adaScript)
            metadata.project.id = project.id.uuidString
            metadata.run.destination = .iPadOS
            metadata.runtime.moduleName = "MobileGame_\(project.id.uuidString.replacingOccurrences(of: "-", with: ""))"
            metadata.runtime.entry = .init(scene: SceneDocumentFormat.defaultScenePath)
            try ProjectSystem.saveProject(metadata, at: directory)
        }

        let sceneURL = directory.appendingPathComponent(SceneDocumentFormat.defaultScenePath)
        if !FileManager.default.fileExists(atPath: sceneURL.path) {
            try SceneDocumentFormat.defaultSceneYAML(projectName: project.title)
                .write(to: sceneURL, atomically: true, encoding: .utf8)
        }
        let sourceURL = sourceDirectory.appendingPathComponent("Game.ada")
        if !FileManager.default.fileExists(atPath: sourceURL.path) {
            try "// Add AdaScript systems for this game.\n"
                .write(to: sourceURL, atomically: true, encoding: .utf8)
        }
        return directory
    }

    static func build(at directory: URL) throws -> EditorAdaScriptProjectBuildArtifact {
        let project = try ProjectSystem.validateProjectLayout(at: directory)
        try ProjectSystem.validateRunCompatibility(of: project, at: directory, destination: .iPadOS)
        return try EditorAdaScriptProjectBuilder().prepare(project: project, at: directory)
    }

    static func buildForAgent(at directory: URL) -> SloppyBuildResult {
        do {
            let artifact = try build(at: directory)
            return SloppyBuildResult(
                ok: true,
                summary: "AdaScript build succeeded: \(artifact.report.sourceCount) source file(s), \(artifact.report.systemCount) system(s)."
            )
        } catch {
            return SloppyBuildResult(ok: false, summary: error.localizedDescription)
        }
    }

    private static func projectsDirectory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
#endif
