import Foundation

/// Whether NVIDIA DLSS can run in this process, and why not when it cannot.
public enum DLSSRuntimeStatus: Equatable, Sendable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool { self == .available }

    public var unavailableReason: String? {
        if case let .unavailable(reason) = self { return reason }
        return nil
    }
}

/// Discovery of the NVIDIA NGX runtime that implements DLSS.
///
/// The SDK is never committed or linked statically. DLSS needs the NGX library and the AdaEngine bridge that wraps the SDK
/// (`Tools/NGXBridge`) in one directory. They are looked up only in an absolute directory named by ``environmentKey`` and
/// then next to the executable, never in the current directory or a `PATH` search.
public enum DLSSRuntime {
    /// Environment variable naming a directory that contains the NGX DLSS runtime library and the bridge.
    public static let environmentKey = "ADAENGINE_NGX_SDK_PATH"

    /// The NGX DLSS runtime library file name for this platform.
    public static var libraryName: String {
        #if os(Windows)
        "nvngx_dlss.dll"
        #else
        // Best effort: NVIDIA ships a versioned name that a later stage resolves with the SDK at hand.
        "libnvidia-ngx-dlss.so"
        #endif
    }

    /// The file name of the AdaEngine NGX bridge that wraps the SDK.
    public static var bridgeName: String {
        #if os(Windows)
        "adaengine_ngx.dll"
        #else
        "libadaengine_ngx.so"
        #endif
    }

    /// The directory that holds both the bridge and the NGX library, or nil.
    public static func locate(environment: [String: String], executableDirectory: String?, fileExists: (String) -> Bool) -> String? {
        searchDirectories(environment: environment, executableDirectory: executableDirectory)
            .first { fileExists(join($0, bridgeName)) && fileExists(join($0, libraryName)) }
    }

    /// Probes the real environment.
    public static func probe() -> DLSSRuntimeStatus {
        probe(
            environment: ProcessInfo.processInfo.environment,
            executableDirectory: Bundle.main.executableURL?.deletingLastPathComponent().path,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    /// Probes with injected inputs. Available means the bridge and the NGX library were found; the GPU is checked later.
    public static func probe(
        environment: [String: String],
        executableDirectory: String?,
        fileExists: (String) -> Bool
    ) -> DLSSRuntimeStatus {
        if locate(environment: environment, executableDirectory: executableDirectory, fileExists: fileExists) != nil {
            return .available
        }
        let directories = searchDirectories(environment: environment, executableDirectory: executableDirectory)
        if let directory = directories.first(where: { fileExists(join($0, libraryName)) }) {
            return .unavailable(
                reason: "NGX runtime found in \(directory), but the AdaEngine bridge (\(bridgeName)) is missing there; build it with the NGX SDK"
            )
        }
        return .unavailable(reason: "NGX runtime (\(libraryName)) not found in \(environmentKey) or next to the executable")
    }

    private static func searchDirectories(environment: [String: String], executableDirectory: String?) -> [String] {
        var directories: [String] = []
        if let configured = environment[environmentKey] { directories.append(configured) }
        if let executableDirectory { directories.append(executableDirectory) }
        return directories.filter(isAbsolute)
    }

    private static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") || directory.hasSuffix("\\") ? directory + name : directory + "/" + name
    }

    private static func isAbsolute(_ path: String) -> Bool {
        if path.hasPrefix("/") || path.hasPrefix("\\\\") { return true }
        let scalars = Array(path.unicodeScalars)
        return scalars.count >= 3 && scalars[1] == ":" && (scalars[2] == "\\" || scalars[2] == "/")
    }
}
