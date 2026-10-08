import Foundation

enum EditorProjectPathDisplayFormatter {
    static func string(for path: String) -> String {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if let iCloudRelativePath = pathSuffix(
            after: "/Mobile Documents/com~apple~CloudDocs/",
            in: standardizedPath
        ) {
            return labeledPath(root: "iCloud Drive", relativePath: iCloudRelativePath)
        }

        let isApplicationContainer =
            standardizedPath.contains("/CoreSimulator/Devices/")
            || standardizedPath.contains("/Containers/Data/Application/")
        if isApplicationContainer,
            let documentsRelativePath = pathSuffix(after: "/Documents/", in: standardizedPath) {
            return labeledPath(root: "On My iPad", relativePath: documentsRelativePath)
        }

        let homePath = NSHomeDirectory()
        if standardizedPath == homePath {
            return "~"
        }
        let displayPath: String
        if standardizedPath.hasPrefix(homePath + "/") {
            displayPath = "~" + standardizedPath.dropFirst(homePath.count)
        } else {
            displayPath = standardizedPath
        }
        guard displayPath.count > 48 else {
            return displayPath
        }
        return compactPath(standardizedPath)
    }

    private static func labeledPath(root: String, relativePath: String) -> String {
        let components = relativePath.split(separator: "/")
        let visibleComponents = components.suffix(2)
        guard !visibleComponents.isEmpty else {
            return root
        }
        return ([root] + visibleComponents.map(String.init)).joined(separator: "/")
    }

    private static func compactPath(_ path: String) -> String {
        let components = URL(fileURLWithPath: path)
            .pathComponents
            .filter { $0 != "/" }
        guard components.count > 2 else {
            return path
        }
        return "…/" + components.suffix(2).joined(separator: "/")
    }

    private static func pathSuffix(after marker: String, in path: String) -> String? {
        guard let markerRange = path.range(of: marker, options: .backwards) else {
            return nil
        }
        return String(path[markerRange.upperBound...])
    }
}
