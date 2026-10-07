import AdaUIDescription
import Foundation

enum EditorAgentA2UIPreviewWriter {
    static func write(_ document: UISceneDocument, surfaceID: String, projectURL: URL, fileManager: FileManager = .default) throws -> String {
        let root = projectURL.standardizedFileURL.resolvingSymlinksInPath()
        var directory = root
        for component in ["Assets", "UI", "AgentPreviews"] {
            directory.appendPathComponent(component, isDirectory: true)
            if let attributes = try? fileManager.attributesOfItem(atPath: directory.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw EditorAgentServiceError.pathOutsideProject(directory.path)
            }
            let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/") else {
                throw EditorAgentServiceError.pathOutsideProject(directory.path)
            }
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            }
        }
        let name = surfaceID.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression).prefix(48)
        let filename = "\(name.isEmpty ? "Interface" : String(name))-\(UUID().uuidString.prefix(8)).ui"
        let url = directory.appendingPathComponent(filename)
        let data = Data(try document.encodedYAML().utf8)
        try data.write(to: url, options: [.withoutOverwriting])
        return "Assets/UI/AgentPreviews/" + filename
    }
}
