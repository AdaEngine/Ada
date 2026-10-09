import Foundation

enum EditorBuildPlatform: String, CaseIterable, Hashable, Sendable {
    case android = "ANDROID"
    case iOS = "IOS"
    case web = "WEB"
    case windows = "WINDOWS"
    case linux = "LINUX"
    case macOS = "MACOS"
    case xr = "VR / XR"

    var title: String {
        switch self {
        case .android: "Android"
        case .iOS: "iOS"
        case .web: "Web"
        case .windows: "Windows"
        case .linux: "Linux"
        case .macOS: "macOS"
        case .xr: "VR / XR"
        }
    }

    static var host: Self {
        #if os(Windows)
        .windows
        #elseif os(Linux)
        .linux
        #else
        .macOS
        #endif
    }

    var detail: String {
        switch self {
        case .android:
            "APK export and device/emulator runs use Android SDK tools directly. Gradle is optional and is not used by the built-in APK exporter."
        case .web:
            "Export and serve WebAssembly games with a matching Swift toolchain and installed Swift WASM SDK."
        case .macOS:
            "Native SwiftPM builds, runs and tests use these tools on macOS. AdaScript macOS export uses the selected Swift compiler."
        case .windows:
            "Native SwiftPM builds use these tools when Studio runs on Windows. Cross-platform Windows packaging from macOS is not available."
        case .linux:
            "Native SwiftPM builds use these tools when Studio runs on Linux. Cross-platform Linux packaging from macOS is not available."
        case .iOS:
            "Xcode and SDK paths for iPhone/iPad development. Studio does not yet provide an iOS game export workflow."
        case .xr:
            "Xcode and visionOS SDK paths for Apple Vision Pro development. Studio does not yet provide XR game export or other VR runtime integrations."
        }
    }

    var fields: [EditorBuildToolField] {
        let swift = EditorBuildToolField("SWIFT_EXECUTABLE", "Swift executable", .executable)
        let apple = [
            EditorBuildToolField("DEVELOPER_DIR", "Xcode Developer directory", .directory),
            EditorBuildToolField("SDKROOT", "Platform SDK directory", .directory)
        ]
        let native = [
            swift,
            EditorBuildToolField("CMAKE_EXECUTABLE", "CMake executable", .executable),
            EditorBuildToolField("NINJA_EXECUTABLE", "Ninja executable", .executable)
        ]
        switch self {
        case .android:
            return EditorAndroidConfiguration.fields.map { key, label in
                let kind: EditorBuildToolField.Kind
                switch key {
                case "SWIFT_ANDROID_SWIFT", "GRADLE_EXECUTABLE": kind = .executable
                case "SWIFT_ANDROID_SDK", "ANDROID_BUILD_TOOLS_VERSION", "SWAN_LOCAL_DAWN": kind = .identifier
                default: kind = .directory
                }
                return EditorBuildToolField(key, label, kind)
            }
        case .web:
            return [
                EditorBuildToolField("ADA_WEB_SWIFT_EXECUTABLE", "Swift WASM executable", .executable),
                EditorBuildToolField("ADA_WEB_SWIFT_SDK", "Swift WASM SDK identifier", .identifier),
                EditorBuildToolField("TINT_EXECUTABLE", "Tint shader compiler", .executable)
            ]
        case .macOS: return [swift] + apple + Array(native.dropFirst())
        case .iOS, .xr: return [swift] + apple
        case .windows:
            return native + [
                EditorBuildToolField("WindowsSdkDir", "Windows SDK directory", .directory),
                EditorBuildToolField("VCToolsInstallDir", "MSVC tools directory", .directory)
            ]
        case .linux: return native + [EditorBuildToolField("CC", "Clang / C compiler", .executable)]
        }
    }
}

struct EditorBuildToolField: Identifiable, Sendable {
    enum Kind: Equatable, Sendable { case executable, directory, identifier }
    let id: String
    let title: String
    let kind: Kind

    init(_ id: String, _ title: String, _ kind: Kind) {
        self.id = id
        self.title = title
        self.kind = kind
    }
}

/// Host-local tool paths; project manifests remain portable.
struct EditorBuildExportConfiguration: Equatable, Sendable {
    static let preferenceKey = "AdaStudio.BuildExport.Tools"
    var values: [String: [String: String]] = [:]

    static func load(defaults: UserDefaults = .standard) -> Self {
        var configuration = Self(values: defaults.dictionary(forKey: preferenceKey) as? [String: [String: String]] ?? [:])
        #if os(macOS)
        let engineRoot: URL? = EditorAndroidConfiguration.studioEngineRoot
        #else
        let engineRoot: URL? = nil
        #endif
        let android = EditorAndroidConfiguration.load(
            engineRoot: engineRoot,
            preferences: defaults.dictionary(forKey: EditorAndroidConfiguration.preferenceKey) as? [String: String]
        )
        configuration.values[EditorBuildPlatform.android.rawValue] = android.environment.filter { key, _ in
            EditorAndroidConfiguration.fields.contains { $0.0 == key }
        }
        return configuration
    }

    func value(_ key: String, for platform: EditorBuildPlatform) -> String {
        values[platform.rawValue]?[key] ?? ""
    }

    func save(defaults: UserDefaults = .standard) {
        var profiles: [String: [String: String]] = [:]
        for platform in EditorBuildPlatform.allCases {
            profiles[platform.rawValue] = Dictionary(uniqueKeysWithValues: platform.fields.compactMap { field in
                let value = normalizedValue(field, for: platform)
                return value.isEmpty ? nil : (field.id, value)
            })
        }
        // Keep the existing Android preference key so installed configurations and
        // all Android build/device consumers continue to use the same values.
        defaults.set(profiles.removeValue(forKey: EditorBuildPlatform.android.rawValue) ?? [:], forKey: EditorAndroidConfiguration.preferenceKey)
        defaults.set(profiles, forKey: Self.preferenceKey)
    }

    func normalizedValue(_ field: EditorBuildToolField, for platform: EditorBuildPlatform) -> String {
        let value = value(field.id, for: platform).trimmingCharacters(in: .whitespacesAndNewlines)
        return field.kind == .identifier ? value : (value as NSString).expandingTildeInPath
    }

    func swiftExecutable(for platform: EditorBuildPlatform) -> String? {
        let key = platform == .web ? "ADA_WEB_SWIFT_EXECUTABLE" : "SWIFT_EXECUTABLE"
        guard let field = platform.fields.first(where: { $0.id == key }) else { return nil }
        let value = normalizedValue(field, for: platform)
        return value.isEmpty ? nil : value
    }

    func environment(for platform: EditorBuildPlatform, basePath: String? = ProcessInfo.processInfo.environment["PATH"]) -> [String: String] {
        var environment: [String: String] = [:]
        var toolDirectories: [String] = []
        for field in platform.fields {
            let value = normalizedValue(field, for: platform)
            guard !value.isEmpty else { continue }
            switch field.id {
            case "SWIFT_EXECUTABLE", "ADA_WEB_SWIFT_EXECUTABLE", "ADA_WEB_SWIFT_SDK": continue
            case "CMAKE_EXECUTABLE", "NINJA_EXECUTABLE", "GRADLE_EXECUTABLE":
                toolDirectories.append(URL(fileURLWithPath: value).deletingLastPathComponent().path)
            default: environment[field.id] = value
            }
        }
        if !toolDirectories.isEmpty {
            #if os(Windows)
            let separator = ";"
            #else
            let separator = ":"
            #endif
            environment["PATH"] = (toolDirectories + [basePath ?? ""]).joined(separator: separator)
        }
        return environment
    }

    func pathStatus(_ field: EditorBuildToolField, for platform: EditorBuildPlatform, fileManager: FileManager = .default) -> String {
        let value = normalizedValue(field, for: platform)
        if value.isEmpty { return "Automatic / not overridden" }
        if field.kind == .identifier { return "Configured" }
        var isDirectory: ObjCBool = false
        let exists = unsafe fileManager.fileExists(atPath: value, isDirectory: &isDirectory)
        if field.kind == .executable {
            return exists && !isDirectory.boolValue && fileManager.isExecutableFile(atPath: value) ? "Available" : "Executable not found"
        }
        return exists && isDirectory.boolValue ? "Available" : "Directory not found"
    }
}
