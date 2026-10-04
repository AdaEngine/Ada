#if os(macOS)
import Foundation

/// A source SDK bundled with standalone Studio; host compilers remain external.
struct EditorBuildSDK: Sendable {
    let engineRoot: URL
    let compilerRoot: URL

    static func appBundle(containing executable: URL) -> URL? {
        var url = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        while url.path != "/" {
            if url.pathExtension == "app" {
                return url
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    static func locate(
        override: String? = nil,
        executable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self {
        if let explicit = override ?? environment["ADA_STUDIO_SDK"] {
            return try load(at: URL(fileURLWithPath: explicit))
        }
        if let bundle = appBundle(containing: executable) {
            return try load(at: bundle.appendingPathComponent("Contents/Resources/BuildSDK"))
        }
        // Only source development builds use a checkout. Installed apps never fall back to #filePath.
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = environment["ADAENGINE_GRAVITY_PACKAGE_PATH"].map { [URL(fileURLWithPath: $0)] } ?? [
            engine.appendingPathComponent("Editor/.build/checkouts/gravity-lang"),
            engine.appendingPathComponent(".build/checkouts/gravity-lang"),
            engine.deletingLastPathComponent().appendingPathComponent("gravity-lang-aot"),
        ]
        guard let compiler = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("tools/aot_build.py").path) }) else {
            throw EditorCLIError.environment("AdaScript build SDK not found. Use --sdk or ADA_STUDIO_SDK.")
        }
        let sdk = Self(engineRoot: engine, compilerRoot: compiler)
        try sdk.validate()
        return sdk
    }

    static func load(at directory: URL) throws -> Self {
        struct Manifest: Decodable { let schemaVersion: Int }
        let manifestURL = directory.appendingPathComponent("sdk.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.schemaVersion == 1 else {
            throw EditorCLIError.environment("Build SDK manifest is missing or unsupported: \(manifestURL.path)")
        }
        let sdk = Self(engineRoot: directory.appendingPathComponent("AdaEngine"), compilerRoot: directory.appendingPathComponent("AdaScript"))
        try sdk.validate()
        return sdk
    }

    func validate() throws {
        for url in [engineRoot.appendingPathComponent("Package.swift"), compilerRoot.appendingPathComponent("Package.swift"), compilerRoot.appendingPathComponent("tools/aot_build.py")] {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw EditorCLIError.environment("Incomplete build SDK: \(url.path)")
            }
        }
        // A packaged SDK is read-only; it must contain the already-built compiler.
        guard FileManager.default.isExecutableFile(atPath: compilerRoot.appendingPathComponent("gravity").path) else {
            throw EditorCLIError.environment("AdaScript compiler is missing. Rebuild the standalone Studio SDK.")
        }
    }
}
#endif
