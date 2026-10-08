import Foundation

extension EditorProjectStore {
    func projectForOpening(at url: URL) throws -> AdaProject {
        do {
            return try ProjectSystem.validateProjectLayout(at: url, fileManager: fileManager)
        } catch ProjectSystemError.metadataFileMissing {
            let buildSystem: AdaProjectBuildSystem = fileManager.fileExists(atPath: url.appendingPathComponent("Package.swift").path) ? .swiftpm : .adaScript
            try distribution.validate(buildSystem: buildSystem)
            if buildSystem.isAdaScript {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.appendingPathComponent("Sources").path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw ProjectSystemError.sourceDirectoryMissing(path: "Sources")
                }
            }
            let name = url.pathExtension.lowercased() == "adaproject" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
            var project = ProjectSystem.defaultProject(projectName: name, buildSystem: buildSystem)
            let scene = inferredStartupScene(at: url)
            project.editor.startupScene = scene
            if buildSystem.isAdaScript {
                project.runtime.entry = .init(scene: scene)
            }
            _ = try ProjectSystem.createProjectIfMissing(project, at: url, fileManager: fileManager)
            return try ProjectSystem.validateProjectLayout(at: url, fileManager: fileManager)
        }
    }

    private func inferredStartupScene(at url: URL) -> String? {
        if fileManager.fileExists(atPath: url.appendingPathComponent(SceneDocumentFormat.defaultScenePath).path) {
            return SceneDocumentFormat.defaultScenePath
        }
        let assetsURL = url.appendingPathComponent("Assets", isDirectory: true).resolvingSymlinksInPath()
        guard let files = fileManager.enumerator(
            at: assetsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return files.compactMap { file -> String? in
            guard let file = file as? URL, ["ascn", "scene", "scn"].contains(file.pathExtension.lowercased()),
                (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            let path = file.resolvingSymlinksInPath().path
            guard path.hasPrefix(assetsURL.path + "/") else {
                return nil
            }
            return "Assets/" + String(path.dropFirst(assetsURL.path.count + 1))
        }.min()
    }
}
