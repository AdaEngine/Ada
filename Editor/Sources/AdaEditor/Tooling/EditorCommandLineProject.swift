#if os(macOS) || os(Windows) || os(Linux)
import Foundation
#if os(Windows)
import WinSDK
#endif

enum EditorCommandLineProject {
    /// Resolve against the caller's working directory before launching the graphical app.
    static func projectURL(arguments: [String], directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws -> URL? {
        var words = Array(arguments.dropFirst())
        if words.first == "--ada-studio-cli" { words.removeFirst() }
        let explicitPath = words.first == "--"
        if explicitPath { words.removeFirst() }
        guard let first = words.first else { return nil }
        let commands: Set<String> = ["help", "version", "doctor", "project", "inspect", "validate", "build", "export", "agent-resources"]
        if !explicitPath, first.hasPrefix("-") || commands.contains(first) { return nil }
        guard words.count == 1, !first.isEmpty else {
            throw EditorCLIError.argument("Pass one project directory: adastudio <directory>.")
        }
        let path = (first as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: directory.path, isDirectory: true)
        return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
    }

    static func open(_ project: URL, executable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])) throws {
        let directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let argument = "--editor-project=\(project.path)"
        #if os(Windows)
        let editor = directory.appendingPathComponent("AdaEditor.exe")
        let result = editor.path.withCString(encodedAs: UTF16.self) { file in
            EditorWindowsProcess.quote(argument).withCString(encodedAs: UTF16.self) { parameters in
                "open".withCString(encodedAs: UTF16.self) { operation in
                    ShellExecuteW(nil, operation, file, parameters, nil, SW_SHOWNORMAL)
                }
            }
        }
        guard Int(bitPattern: result) > 32 else { throw EditorCLIError.environment("Unable to launch Ada Studio (Windows error \(Int(bitPattern: result))).") }
        #else
        let process = Process()
        #if os(macOS)
        if let app = EditorBuildSDK.appBundle(containing: executable) {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", "-a", app.path, "--args", argument]
        } else {
            process.executableURL = directory.appendingPathComponent("AdaEditor")
            process.arguments = [argument]
        }
        #else
        process.executableURL = directory.appendingPathComponent("ada-studio")
        process.arguments = [argument]
        #endif
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        #if os(macOS)
        if process.executableURL?.path == "/usr/bin/open" {
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw EditorCLIError.environment("Unable to launch Ada Studio.") }
        }
        #endif
        #endif
    }
}
#endif
