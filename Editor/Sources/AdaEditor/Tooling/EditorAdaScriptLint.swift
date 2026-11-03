#if os(macOS) || os(Windows) || os(Linux)
import AdaScriptCompilerCore
import Foundation

/// Checks authored sources and tests, without linting third-party libraries or writing files.
enum EditorAdaScriptLint {
    static func diagnostics(project: AdaProject, at root: URL) throws -> [EditorCLIDiagnostic] {
        let sourcePath = project.paths.sources ?? "Sources"
        let folders = Array(Set([sourcePath, "Tests"])).sorted()
        var diagnostics: [EditorCLIDiagnostic] = []
        var visited = Set<URL>()
        for folder in folders {
            let directory = root.appendingPathComponent(folder).standardizedFileURL
            guard FileManager.default.fileExists(atPath: directory.path) else {
                continue
            }
            let directoryValues = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard directoryValues.isSymbolicLink != true else {
                continue
            }
            guard let files = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let file as URL in files {
                try Task.checkCancellation()
                // Windows hidden attributes do not cover dot-prefixed project folders.
                if file.lastPathComponent.hasPrefix(".") {
                    files.skipDescendants()
                    continue
                }
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    files.skipDescendants()
                    continue
                }
                guard values.isRegularFile == true, ["ada", "gravity"].contains(file.pathExtension.lowercased()),
                    visited.insert(file.standardizedFileURL).inserted else {
                    continue
                }
                let relative = String(file.path.dropFirst(directory.path.count + 1))
                if folder == sourcePath, !project.includesSource(relativePath: relative) {
                    continue
                }
                let text = try String(contentsOf: file, encoding: .utf8)
                diagnostics += AdaScriptLinter.lint(source: text).map { issue in
                    EditorCLIDiagnostic(
                        code: "adascript-lint.\(issue.rule.rawValue)",
                        severity: "warning",
                        message: issue.rule.message,
                        file: folder + "/" + relative,
                        line: issue.range.start.line + 1,
                        column: issue.range.start.utf16Column + 1
                    )
                }
            }
        }
        return diagnostics.sorted {
            if $0.file != $1.file {
                return ($0.file ?? "") < ($1.file ?? "")
            }
            if $0.line != $1.line {
                return ($0.line ?? 0) < ($1.line ?? 0)
            }
            if $0.column != $1.column {
                return ($0.column ?? 0) < ($1.column ?? 0)
            }
            return $0.code < $1.code
        }
    }
}
#endif
