import Foundation

enum SceneDocumentFormat {
    static let canonicalExtension = "ascn"
    static let supportedExtensions: Set<String> = ["ascn", "scene", "scn"]
    static let defaultScenePath = "Assets/Scenes/Main.ascn"

    static func isSceneFile(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func defaultSceneYAML(projectName: String) -> String {
        (try? EditorSceneModel.default(projectName: projectName).encodedYAML()) ?? "format: ada.scene\nschemaVersion: 1\nentities: []\n"
    }
}
