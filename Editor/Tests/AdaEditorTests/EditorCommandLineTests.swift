#if os(macOS) || os(Windows) || os(Linux)
import Foundation
import Testing
#if os(Windows)
import WinSDK
#endif

@testable import AdaEditor

@Suite("Studio command installation and project launch")
struct EditorCommandLineTests {
    @Test func resolvesCallerDirectoryAndPreservesCLICommands() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Игра с пробелами \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectSystem.defaultProject(projectName: "Моя игра", buildSystem: .adaScript)
        try ProjectSystem.saveProject(project, at: root)
        for words in [["adastudio", "."], ["AdaEditor", "--ada-studio-cli", "."], ["adastudio", root.path]] {
            let url = try #require(try EditorCommandLineProject.projectURL(arguments: words, directory: root))
            #expect(url.path == root.path)
            #expect(try ProjectSystem.validateProjectLayout(at: url).project.name == "Моя игра")
        }
        for command in ["help", "--help", "--version", "doctor", "project", "inspect", "validate", "build", "export", "agent-resources"] {
            #expect(try EditorCommandLineProject.projectURL(arguments: ["adastudio", command], directory: root) == nil)
        }
        #expect(try EditorCommandLineProject.projectURL(arguments: ["adastudio", "--", "build"], directory: root)?.path == root.appendingPathComponent("build").path)
        let sibling = root.deletingLastPathComponent().appendingPathComponent("Other Game")
        #expect(try EditorCommandLineProject.projectURL(arguments: ["adastudio", "../Other Game"], directory: root)?.path == sibling.path)
        #expect(throws: EditorCLIError.self) { try EditorCommandLineProject.projectURL(arguments: ["adastudio", ".", "another"]) }
    }

    @Test func opensUnregisteredProjectDirectoriesThroughTheOrdinaryLoader() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EditorProjectStore(storageURL: root.appendingPathComponent("recents.json"), distribution: .standalone)
        for swift in [false, true] {
            let folder = root.appendingPathComponent(swift ? "Swift Game" : "AdaScript Game")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("Sources"), withIntermediateDirectories: true)
            if swift { try "// swift-tools-version: 6.2\n".write(to: folder.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8) }
            if !swift {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("Assets"), withIntermediateDirectories: true)
                try EditorSceneModel.default(projectName: "AdaScript Game").encodedYAML()
                    .write(to: folder.appendingPathComponent("Assets/Main.ascn"), atomically: true, encoding: .utf8)
            }
            let url = try #require(try EditorCommandLineProject.projectURL(arguments: ["adastudio", folder.path], directory: root))
            let project = try store.projectForOpening(at: url)
            #expect(project.build.system == (swift ? .swiftpm : .adaScript))
            #expect(try ProjectSystem.validateProjectLayout(at: url).project.name == folder.lastPathComponent)
        }
    }

    #if os(Windows)
    @Test func userPathPreservesExistingEntriesAndInstallationIsIdempotent() throws {
        let path = "%USERPROFILE%\\Tools;C:\\Tools;"
        let directory = URL(fileURLWithPath: "C:\\Игры\\Ada Studio")
        let updated = EditorCLIWindowsPath.appending("C:\\Игры\\Ada Studio", to: path)
        #expect(updated == path + "C:\\Игры\\Ada Studio")
        #expect(EditorCLIWindowsPath.appending("c:/игры/ada studio/", to: updated) == updated)
        #expect(EditorCLIWindowsPath.appending("C:\\Tools", to: "\"c:\\tools\\\"") == "\"c:\\tools\\\"")

        // Exercise the production registry writer in a disposable key, never the user's real PATH.
        let registry = "Software\\AdaStudioTests-\(UUID().uuidString)"
        defer { _ = registry.withCString(encodedAs: UTF16.self) { RegDeleteKeyW(HKEY_CURRENT_USER, $0) } }
        try EditorCLIWindowsPath.install(directory: directory, registryPath: registry, notify: false)
        try EditorCLIWindowsPath.install(directory: directory, registryPath: registry, notify: false)
        var key: HKEY?
        let status = registry.withCString(encodedAs: UTF16.self) { RegOpenKeyExW(HKEY_CURRENT_USER, $0, 0, DWORD(KEY_QUERY_VALUE), &key) }
        #expect(status == ERROR_SUCCESS)
        let handle = try #require(key)
        defer { RegCloseKey(handle) }
        var bytes = [UInt16](repeating: 0, count: 1024)
        var count = DWORD(bytes.count * 2)
        var type: DWORD = 0
        let read = bytes.withUnsafeMutableBytes { buffer in
            "Path".withCString(encodedAs: UTF16.self) { RegQueryValueExW(handle, $0, nil, &type, buffer.bindMemory(to: BYTE.self).baseAddress, &count) }
        }
        #expect(read == ERROR_SUCCESS)
        #expect(type == REG_EXPAND_SZ)
        #expect(String(decoding: bytes.prefix { $0 != 0 }, as: UTF16.self) == "C:\\Игры\\Ada Studio")
    }
    #else
    @Test func installsRealLauncherAndShellProfilesWithoutOverwritingUserSettings() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Ada ' тест $home \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let launcher = home.appendingPathComponent("Studio ' app")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let profile = home.appendingPathComponent(".bash_profile")
        try "export MY_SETTING=kept\n".write(to: profile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profile.path)
        let dotfile = home.appendingPathComponent("shared-profile")
        try "export SHARED=kept\n".write(to: dotfile, atomically: true, encoding: .utf8)
        let profileLink = home.appendingPathComponent(".profile")
        try FileManager.default.createSymbolicLink(at: profileLink, withDestinationURL: dotfile)
        let bin = try EditorCLIInstallation.installPOSIX(launcher: launcher, home: home, environment: [:])
        let first = try String(contentsOf: profile, encoding: .utf8)
        _ = try EditorCLIInstallation.installPOSIX(launcher: launcher, home: home, environment: [:])
        #expect(try String(contentsOf: profile, encoding: .utf8) == first)
        #expect(first.hasPrefix("export MY_SETTING=kept\n"))
        let permissions = try FileManager.default.attributesOfItem(atPath: profile.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: profileLink.path) == dotfile.path)
        #expect(try String(contentsOf: dotfile, encoding: .utf8).hasPrefix("export SHARED=kept\n"))
        #expect(FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent("adastudio").path))
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ". \(EditorCLIInstallation.shellQuote(profile.path)); adastudio 'My Game' --literal"]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path]
        process.standardOutput = output
        try process.run()
        let data = try #require(try output.fileHandleForReading.readToEnd())
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: data, as: UTF8.self) == "--ada-studio-cli\nMy Game\n--literal\n")
        let command = bin.appendingPathComponent("adastudio")
        try "user command".write(to: command, atomically: true, encoding: .utf8)
        #expect(throws: EditorCLIInstallation.InstallationError.self) {
            try EditorCLIInstallation.installPOSIX(launcher: launcher, home: home, environment: [:])
        }
        #expect(try String(contentsOf: command, encoding: .utf8) == "user command")
    }
    #endif
}
#endif
