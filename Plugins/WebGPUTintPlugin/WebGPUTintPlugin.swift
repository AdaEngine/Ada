import Foundation
import PackagePlugin

/// The command plugin and development scripts share one pinned, verified cache.
@main
struct WebGPUTintPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        if ProcessInfo.processInfo.environment["ADAENGINE_SKIP_WEBGPU_PLUGINS"]?.isEmpty == false {
            Diagnostics.remark("Skipping Tint bootstrap (ADAENGINE_SKIP_WEBGPU_PLUGINS is set)")
            return
        }
        let pluginPackage = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [context.package.directoryURL, pluginPackage].map { $0.appendingPathComponent("script/ensure_tint.py") }
        guard let script = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw BootstrapError.missingScript("script/ensure_tint.py")
        }
        let process = Process()
        #if os(Windows)
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ";")
        guard let python = paths.map({ URL(fileURLWithPath: String($0)).appendingPathComponent("python.exe") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw BootstrapError.missingScript("Python 3 is required on PATH")
        }
        process.executableURL = python
        process.arguments = [script.path] + arguments
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path] + arguments
        #endif
        process.currentDirectoryURL = context.package.directoryURL
        var environment = ProcessInfo.processInfo.environment
        if environment["ADAENGINE_TINT_CACHE"]?.isEmpty != false {
            // Dependent games keep writes inside the package authorized by SwiftPM.
            environment["ADAENGINE_TINT_CACHE"] = context.package.directoryURL.appendingPathComponent(".build-tools/tint").path
        }
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BootstrapError.failed(process.terminationStatus)
        }
        Diagnostics.remark("Tint SPIR-V reader / WGSL writer cache verified")
    }

    enum BootstrapError: Error {
        case missingScript(String)
        case failed(Int32)
    }
}
