import AdaEngine
import Foundation

enum MobileEditorSceneValidation {
    /// Uses the Play scene loader so component and binding warnings are returned to the agent as build errors.
    @MainActor
    static func validate(_ artifact: EditorAdaScriptProjectBuildArtifact, at projectURL: URL) throws {
        guard let model = artifact.sceneModel, let path = artifact.entry.scene else {
            return
        }
        EditorComponentRegistry.registerBuiltIns()
        try artifact.scenePlayRuntime.registerScriptableObjects()
        let result = EditorSceneFileLoader.load(
            model: model,
            into: World(name: "Mobile Studio scene validation"),
            sourceURL: projectURL.appendingPathComponent(path),
            resourceRootURL: artifact.assetsDirectory
        )
        guard result.warnings.isEmpty else {
            throw EditorAdaScriptProjectBuildError.startupSceneInvalid(
                path: path,
                message: result.warnings.joined(separator: "\n")
            )
        }
    }
}
