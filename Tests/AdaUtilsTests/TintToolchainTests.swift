import AdaUtils
import Foundation
import Testing

@Suite("Tint host tool discovery")
struct TintToolchainTests {
    @Test func overrideAndCachePriority() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tint-discovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let name = TintToolchain.platform.hasSuffix("windows") ? "tint.exe" : "tint"
        func executable(_ path: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        let project = try executable(".build-tools/tint/bin/\(TintToolchain.platform)/\(name)")
        let custom = try executable("custom/bin/\(TintToolchain.platform)/\(name)")
        let path = try executable("path/\(name)")
        let override = try executable("override/\(name)")
        var environment = ["PATH": path.deletingLastPathComponent().path]
        #expect(TintToolchain.executable(environment: environment, packageRoot: root) == project)
        environment["ADAENGINE_TINT_CACHE"] = root.appendingPathComponent("custom").path
        #expect(TintToolchain.executable(environment: environment, packageRoot: root) == custom)
        environment["TINT_EXECUTABLE"] = override.path
        #expect(TintToolchain.executable(environment: environment, packageRoot: root) == override)
        environment["TINT_EXECUTABLE"] = root.appendingPathComponent("missing").path
        #expect(TintToolchain.executable(environment: environment, packageRoot: root) == nil)
        try FileManager.default.removeItem(at: project)
        #expect(TintToolchain.executable(environment: ["PATH": path.deletingLastPathComponent().path], packageRoot: root) == path)
    }
}
