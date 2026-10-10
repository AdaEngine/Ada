import Foundation

/// Shared host-tool discovery for shader development. Building stays outside the runtime.
public enum TintToolchain {
    public static var platform: String {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        #if os(macOS)
        return "\(architecture)-macos"
        #elseif os(Windows)
        return "\(architecture)-windows"
        #else
        return "\(architecture)-linux"
        #endif
    }

    /// Override, bundled tool, project tool cache, then PATH. Returns nil for an invalid explicit override.
    public static func executable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle? = nil,
        packageRoot: URL? = nil
    ) -> URL? {
        let manager = FileManager.default
        if let override = environment["TINT_EXECUTABLE"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return manager.isExecutableFile(atPath: url.path) ? url : nil
        }
        #if os(Windows)
        let name = "tint.exe"
        let separator: Character = ";"
        #else
        let name = "tint"
        let separator: Character = ":"
        #endif
        var candidates: [URL] = []
        if let bundle, let bundled = bundle.url(forResource: "tint", withExtension: name == "tint" ? nil : "exe") {
            candidates.append(bundled)
        }
        if let cache = environment["ADAENGINE_TINT_CACHE"], !cache.isEmpty {
            candidates.append(URL(fileURLWithPath: cache).appendingPathComponent("bin/\(platform)/\(name)"))
        }
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = packageRoot ?? sourceRoot
        candidates.append(root.appendingPathComponent(".build-tools/tint/bin/\(platform)/\(name)"))
        candidates += (environment["PATH"] ?? "").split(separator: separator).map {
            URL(fileURLWithPath: String($0)).appendingPathComponent(name)
        }
        return candidates.first { manager.isExecutableFile(atPath: $0.path) }
    }
}
