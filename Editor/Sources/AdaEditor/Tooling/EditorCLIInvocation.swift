#if os(macOS)
import Foundation

/// Strict, noninteractive command contract shared by the bundled CLI and its tests.
struct EditorCLIInvocation: Sendable {
    enum Command: String, Sendable { case help, version, doctor, inspect, validate, build, export }
    enum Format: String, Sendable { case text, json }

    let command: Command
    let format: Format
    let projectURL: URL
    let options: [String: String]

    init(arguments: [String], directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws {
        var words = arguments
        if words.first == "project" {
            words.removeFirst()
            guard words.first == "inspect" else { throw EditorCLIError.argument("Expected 'project inspect'.") }
        }
        let first = words.first ?? "--help"
        switch first {
        case "--help", "help", "-h": command = .help
        case "--version", "version": command = .version
        case "doctor": command = .doctor
        case "inspect": command = .inspect
        case "validate": command = .validate
        case "build": command = .build
        case "export": command = .export
        default: throw EditorCLIError.argument("Unknown command '\(first)'. Use --help.")
        }
        let common: Set<String> = ["format"]
        let project: Set<String> = ["project"]
        let toolchain: Set<String> = ["sdk", "swift"]
        let build: Set<String> = ["target", "configuration", "output", "scratch-path", "swift-sdk", "product", "abi", "device", "emulator", "android-sdk", "ndk", "swift-sdks", "swan", "dawn"]
        let allowed: Set<String>
        switch command {
        case .help, .version: allowed = common
        case .doctor: allowed = common.union(toolchain)
        case .inspect, .validate: allowed = common.union(project)
        case .build, .export: allowed = common.union(project).union(toolchain).union(build)
        }
        var parsed: [String: String] = [:]
        var index = 1
        while index < words.count {
            let flag = words[index]
            guard flag.hasPrefix("--"), allowed.contains(String(flag.dropFirst(2))) else {
                throw EditorCLIError.argument("Unknown option '\(flag)' for \(command.rawValue).")
            }
            let key = String(flag.dropFirst(2))
            guard parsed[key] == nil else { throw EditorCLIError.argument("Duplicate option '\(flag)'.") }
            guard index + 1 < words.count, !words[index + 1].hasPrefix("--"), !words[index + 1].isEmpty else {
                throw EditorCLIError.argument("Missing value for '\(flag)'.")
            }
            parsed[key] = words[index + 1]
            index += 2
        }
        guard let format = Format(rawValue: parsed["format"] ?? "text") else {
            throw EditorCLIError.argument("--format must be text or json.")
        }
        if let configuration = parsed["configuration"], !["debug", "release"].contains(configuration) {
            throw EditorCLIError.argument("--configuration must be debug or release.")
        }
        if let target = parsed["target"], !["macos", "web", "android"].contains(target) {
            throw EditorCLIError.argument("--target must be macos, web or android. iOS export is not available yet.")
        }
        if command == .build, parsed["target"] == "web" {
            throw EditorCLIError.argument("Use 'export --target web' for Web output.")
        }
        let androidOptions: Set<String> = ["product", "abi", "device", "emulator", "android-sdk", "ndk", "swift-sdks", "swan", "dawn"]
        if parsed["target"] != "android", !androidOptions.isDisjoint(with: parsed.keys) {
            throw EditorCLIError.argument("Android options require --target android.")
        }
        if parsed["device"] != nil, parsed["emulator"] != nil { throw EditorCLIError.argument("Choose --device or --emulator, not both.") }
        if let abi = parsed["abi"], !["arm64-v8a", "x86_64", "all"].contains(abi) { throw EditorCLIError.argument("Unsupported Android ABI.") }
        self.format = format
        options = parsed
        projectURL = URL(fileURLWithPath: parsed["project"] ?? directory.path, relativeTo: directory).standardizedFileURL
    }

    static let help = """
    Ada Studio CLI

    Usage: adastudio <command> [options]
      --help                     Show this help
      --version                  Show CLI and protocol versions
      doctor                     Check the build SDK and host tools
      project inspect            Read project metadata without writing it
      validate                   Check metadata, AdaScript and the entry scene
      build                      Build an AdaScript macOS .app
      export                     Export a macOS .app, Web bundle or Android APK

    Common:    --format text|json
    Project:   --project <directory> (default: current directory)
    Build:     --target macos|web|android --configuration debug|release --output <directory>
               --scratch-path <directory> --swift-sdk <SDK identifier> (Web)
    Android:   --product <Swift product> --abi arm64-v8a|x86_64|all
               --device <adb serial> or --emulator <AVD name> to also install/run
               --android-sdk <path> --ndk <path> --swift-sdks <path>
               --swan <package path> --dawn <artifact path relative to Swan>
    Toolchain: --sdk <BuildSDK directory> --swift <Swift executable>

    Installed: "/Applications/Ada Studio.app/Contents/MacOS/adastudio" <command>
    Source:    swift run AdaEditor --ada-studio-cli <command>
    Build/export require standalone Studio, Xcode command-line tools and Python 3.
    Web export additionally requires a matching Swift WebAssembly SDK.
    Validation reads saved files; it does not validate every asset or execute gameplay.
    JSON goes to stdout, build logs to stderr. No UI or prompts are opened.
    Exit codes: 0 success, 2 usage, 3 project, 4 environment, 5 build, 130 cancelled.
    """
}

enum EditorCLIError: Error, LocalizedError, Sendable {
    case argument(String)
    case environment(String)
    case project(String)
    case build(String)

    var errorDescription: String? {
        switch self {
        case let .argument(message), let .environment(message), let .project(message), let .build(message): message
        }
    }

    var exitCode: Int32 {
        switch self {
        case .argument: 2
        case .project: 3
        case .environment: 4
        case .build: 5
        }
    }
}
#endif
