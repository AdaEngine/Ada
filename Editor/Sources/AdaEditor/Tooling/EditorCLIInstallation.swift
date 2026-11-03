#if os(macOS) || os(Windows) || os(Linux)
#if os(macOS)
import Darwin
#endif
import Foundation
#if os(Linux)
import Glibc
#endif

/// Installs for the current user without changing the app or requiring administrator privileges.
enum EditorCLIInstallation {
    static let marker = "# Ada Studio command line"

    static func install(executable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])) throws -> URL {
        let directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        #if os(Windows)
        let launcher = directory.appendingPathComponent("adastudio.exe")
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else { throw InstallationError.launcherUnavailable }
        try EditorCLIWindowsPath.install(directory: directory)
        return directory
        #else
        #if os(macOS)
        let launcher = directory.appendingPathComponent("adastudio")
        #else
        // The staged launcher supplies the bundled Swift runtime and SDK environment.
        let launcher = directory.appendingPathComponent("ada-studio")
        #endif
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else { throw InstallationError.launcherUnavailable }
        return try installPOSIX(launcher: launcher, home: FileManager.default.homeDirectoryForCurrentUser,
                                environment: ProcessInfo.processInfo.environment)
        #endif
    }

    #if !os(Windows)
    static func installPOSIX(launcher: URL, home: URL, environment: [String: String]) throws -> URL {
        let manager = FileManager.default
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        let command = bin.appendingPathComponent("adastudio")
        if manager.fileExists(atPath: command.path) || (try? manager.destinationOfSymbolicLink(atPath: command.path)) != nil {
            let attributes = try manager.attributesOfItem(atPath: command.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  try String(contentsOf: command, encoding: .utf8).hasPrefix("#!/bin/sh\n\(marker)\n") else {
                throw InstallationError.existingCommand(command.path)
            }
        }
        try manager.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = "#!/bin/sh\n\(marker)\nexec \(shellQuote(launcher.path)) --ada-studio-cli \"$@\"\n"
        try script.write(to: command, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)

        let path = shellQuote(bin.path)
        let block = "\(marker)\ncase \":$PATH:\" in\n  *:\(path):*) ;;\n  *) export PATH=\(path):\"$PATH\" ;;\nesac\n# End Ada Studio command line"
        let zshHome = environment["ZDOTDIR"].map { URL(fileURLWithPath: $0, relativeTo: home).standardizedFileURL } ?? home
        var profiles = [home.appendingPathComponent(".profile"), home.appendingPathComponent(".bashrc"),
                        zshHome.appendingPathComponent(".zprofile"), zshHome.appendingPathComponent(".zshrc")]
        // Bash reads only the first existing login profile, which can hide .profile.
        if let login = [".bash_profile", ".bash_login"].map({ home.appendingPathComponent($0) }).first(where: { manager.fileExists(atPath: $0.path) }) {
            profiles.append(login)
        }
        for profile in profiles { try updateProfile(profile, block: block) }
        let config = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0, relativeTo: home).standardizedFileURL }
            ?? home.appendingPathComponent(".config")
        let fish = config.appendingPathComponent("fish/conf.d/adastudio-path.fish")
        let fishPath = "'" + bin.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
        try updateProfile(fish, block: "\(marker)\ncontains -- \(fishPath) $PATH; or set -gx PATH \(fishPath) $PATH\n# End Ada Studio command line")
        return bin
    }

    private static func updateProfile(_ url: URL, block: String) throws {
        let manager = FileManager.default
        let exists = manager.fileExists(atPath: url.path)
        var text = exists ? try String(contentsOf: url, encoding: .utf8) : ""
        if let start = text.range(of: marker + "\n") {
            guard let end = text.range(of: "# End Ada Studio command line", range: start.upperBound..<text.endIndex) else {
                throw InstallationError.damagedProfile(url.path)
            }
            text.replaceSubrange(start.lowerBound..<end.upperBound, with: block)
        } else {
            text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + "\n" + block + "\n"
        }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Follow a user's symlinked dotfile, preserving the symlink and file permissions.
        let destination = url.resolvingSymlinksInPath()
        if exists {
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".adastudio-\(UUID().uuidString)")
            try manager.copyItem(at: destination, to: temporary)
            defer { try? manager.removeItem(at: temporary) }
            try text.write(to: temporary, atomically: false, encoding: .utf8)
            guard rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            try text.write(to: destination, atomically: true, encoding: .utf8)
        }
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
    #endif

    enum InstallationError: Error {
        case launcherUnavailable
        case existingCommand(String)
        case damagedProfile(String)
        case registry(Int32)
    }
}
#endif
