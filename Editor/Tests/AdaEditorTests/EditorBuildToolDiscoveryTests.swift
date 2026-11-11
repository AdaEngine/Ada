@testable import AdaEditor
import Foundation
import Testing

@Suite("Build tool discovery")
struct EditorBuildToolDiscoveryTests {
    @Test func detectsToolsInstalledAfterFirstScan() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(EditorBuildToolDiscovery.discover(environment: fixture.environment, home: fixture.root)["ANDROID_HOME"] == nil)
        try fixture.executable("Android/Sdk/platform-tools/adb")
        let result = EditorBuildToolDiscovery.discover(environment: fixture.environment, home: fixture.root)
        #expect(result["ANDROID_HOME"] == fixture.root.appendingPathComponent("Android/Sdk").path)
    }

    @Test func validatesSDKAndFindsNewestCompleteComponents() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.directory("Android/Sdk")
        #expect(EditorBuildToolDiscovery.discover(environment: fixture.environment, home: fixture.root)["ANDROID_HOME"] == nil)
        try fixture.executable("Android/Sdk/platform-tools/adb")
        try fixture.file("Android/Sdk/ndk/9.0/source.properties")
        try fixture.file("Android/Sdk/ndk/27.1/source.properties")
        try fixture.directory("Android/Sdk/ndk/99.0") // Interrupted installation.
        try fixture.executable("Android/Sdk/build-tools/35.0.0/aapt2")
        try fixture.directory("Android/Sdk/build-tools/36.0.0")
        let result = EditorBuildToolDiscovery.discover(environment: fixture.environment, home: fixture.root)
        #expect(result["ANDROID_NDK_HOME"] == fixture.root.appendingPathComponent("Android/Sdk/ndk/27.1").path)
        #expect(result["ANDROID_BUILD_TOOLS_VERSION"] == "35.0.0")
    }

    @Test func detectsVersionedSwiftOutsidePATHAndRequiresJDKCompiler() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #if os(Windows)
        let swift = try fixture.executable("Programs/Swift/Toolchains/6.3.1+Asserts/usr/bin/swift")
        #else
        let swift = try fixture.executable("Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin/swift")
        #endif
        let java = try fixture.executable("JDK/bin/java")
        var environment = fixture.environment
        environment["JAVA_HOME"] = java.deletingLastPathComponent().deletingLastPathComponent().path
        let first = EditorBuildToolDiscovery.discover(environment: environment, home: fixture.root)
        #expect(first["SWIFT_EXECUTABLE"] == swift.path)
        #expect(first["JAVA_HOME"] != environment["JAVA_HOME"])
        try fixture.executable("JDK/bin/javac")
        #expect(EditorBuildToolDiscovery.discover(environment: environment, home: fixture.root)["JAVA_HOME"] == environment["JAVA_HOME"])
    }

    @Test func repairsBrokenPathsWithoutOverwritingValidOverridesOrNewEdits() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let preferred = try fixture.executable("Preferred/swift")
        let discovered = try fixture.executable("Discovered/swift")
        var configuration = EditorBuildExportConfiguration()
        configuration.values[EditorBuildPlatform.host.rawValue] = ["SWIFT_EXECUTABLE": preferred.path]
        #expect(configuration.applyDiscoveredTools(["SWIFT_EXECUTABLE": discovered.path], for: .host, unchangedSince: configuration) == 0)
        configuration.values[EditorBuildPlatform.host.rawValue]?["SWIFT_EXECUTABLE"] = fixture.root.appendingPathComponent("Missing/swift").path
        #expect(configuration.applyDiscoveredTools(["SWIFT_EXECUTABLE": discovered.path], for: .host, unchangedSince: configuration) == 1)
        let snapshot = configuration
        configuration.values[EditorBuildPlatform.host.rawValue]?["SWIFT_EXECUTABLE"] = "User is editing this"
        #expect(configuration.applyDiscoveredTools(["SWIFT_EXECUTABLE": preferred.path], for: .host, unchangedSince: snapshot) == 0)
        #expect(configuration.value("SWIFT_EXECUTABLE", for: .host) == "User is editing this")
    }

    #if os(Windows)
    @Test func neverWritesNativeToolsIntoWSLProfile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tool = try fixture.executable("Tools/swift")
        var configuration = EditorBuildExportConfiguration()
        let found = ["ADA_WEB_SWIFT_EXECUTABLE": tool.path, "ADAENGINE_SAGA_PACKAGE_PATH": tool.path]
        #expect(configuration.applyDiscoveredTools(found, for: .web, unchangedSince: configuration) == 0)
        #expect(configuration.values.isEmpty)
    }

    @Test func savedPathsSurviveASeparateProcess() async throws {
        let key = "ADA_STUDIO_TOOL_PREFS_TEST_DOMAIN"
        let swift = "C:/Tools/Тест Swift/swift.exe"
        let android = "C:/SDK/Тест Android"
        if let domain = ProcessInfo.processInfo.environment[key] {
            let defaults = try #require(UserDefaults(suiteName: domain))
            let configuration = EditorBuildExportConfiguration.load(defaults: defaults)
            #expect(configuration.swiftExecutable(for: .host) == swift)
            #expect(configuration.value("ANDROID_HOME", for: .android) == android)
            return
        }
        let domain = "AdaToolPreferencesTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            _ = defaults.synchronize()
        }
        var configuration = EditorBuildExportConfiguration()
        configuration.values[EditorBuildPlatform.host.rawValue] = ["SWIFT_EXECUTABLE": swift]
        configuration.values[EditorBuildPlatform.android.rawValue] = ["ANDROID_HOME": android]
        #expect(configuration.save(defaults: defaults))
        let executable = try #require(Bundle.main.executableURL)
        let result = await EditorProcessRunner().run(EditorProcessCommand(
            executablePath: executable.path,
            arguments: ["--testing-library", "swift-testing", "--filter", "savedPathsSurviveASeparateProcess", "--no-parallel"],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: [key: domain]
        ))
        #expect(result.succeeded, "\(result.combinedOutput)")
    }
    #endif

    @Test func doesNotMixComponentsWhenSDKChangesDuringScan() throws {
        var configuration = EditorBuildExportConfiguration()
        let snapshot = configuration
        configuration.values[EditorBuildPlatform.android.rawValue] = ["ANDROID_HOME": "/New SDK"]
        #expect(configuration.applyDiscoveredTools(["ANDROID_BUILD_TOOLS_VERSION": "35.0.0"], for: .android, unchangedSince: snapshot) == 0)
        #expect(configuration.value("ANDROID_BUILD_TOOLS_VERSION", for: .android).isEmpty)
    }

    @Test func fillsNewSDKAndItsComponentsTogether() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.executable("Android/Sdk/platform-tools/adb")
        try fixture.file("Android/Sdk/ndk/27.1/source.properties")
        var configuration = EditorBuildExportConfiguration()
        let found = ["ANDROID_HOME": fixture.root.appendingPathComponent("Android/Sdk").path,
                     "ANDROID_NDK_HOME": fixture.root.appendingPathComponent("Android/Sdk/ndk/27.1").path,
                     "ANDROID_BUILD_TOOLS_VERSION": "35.0.0"]
        #expect(configuration.applyDiscoveredTools(found, for: .android, unchangedSince: configuration) == 3)
    }

    private struct Fixture {
        let root: URL
        let environment: [String: String]
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Ada tools Тест " + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            environment = ["LOCALAPPDATA": root.path, "ProgramFiles": root.appendingPathComponent("Program Files").path,
                           "ProgramFiles(x86)": root.appendingPathComponent("Program Files x86").path,
                           "SystemDrive": root.path, "PATH": "", "ANDROID_HOME": root.appendingPathComponent("Android/Sdk").path]
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func directory(_ relative: String) throws {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(relative), withIntermediateDirectories: true)
        }
        func file(_ relative: String) throws {
            let target = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: target)
        }
        @discardableResult func executable(_ relative: String) throws -> URL {
            #if os(Windows)
            let target = root.appendingPathComponent(relative + ".exe")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let source = try #require(Bundle.main.executableURL)
            try FileManager.default.copyItem(at: source, to: target)
            #else
            let target = root.appendingPathComponent(relative)
            try file(relative)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            #endif
            return target
        }
    }
}
