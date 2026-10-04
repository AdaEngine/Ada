#if os(macOS)
import Foundation
import Testing

@testable import AdaEditor

@Suite("Ada Studio CLI", .serialized)
struct EditorCLITests {
    @Test func strictArguments() throws {
        let command = try EditorCLIInvocation(arguments: ["project", "inspect", "--project", "/tmp/Game With Spaces", "--format", "json"])
        #expect(command.command == .inspect)
        #expect(command.projectURL.path == "/tmp/Game With Spaces")
        #expect(command.format == .json)
        for words in [
            ["build", "--configuration", "fast"], ["validate", "--unknown", "x"], ["build", "--output"],
            ["validate", "--format", "json", "--format", "text"], ["project", "build"], ["build", "--target", "ios"],
            ["build", "--target", "web"], ["validate", "extra"]
        ] {
            #expect(throws: EditorCLIError.self) { try EditorCLIInvocation(arguments: words) }
        }
        #expect(EditorCLI.isInvocation(["/Applications/Ada Studio.app/Contents/MacOS/adastudio", "validate"]))
        #expect(EditorCLI.isInvocation(["AdaEditor", "--ada-studio-cli", "validate"]))
        #expect(!EditorCLI.isInvocation(["AdaEditor", "--ada-player"]))
        #expect(!EditorCLI.isInvocation(["AdaEditor", "something", "--ada-studio-cli"]))
    }

    @Test func inspectAndValidateDoNotRewriteProject() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = ProjectSystem.metadataURL(forProjectAt: root)
        let before = try Data(contentsOf: metadata)
        for command in ["inspect", "validate"] {
            let report = await EditorCLI.execute(try EditorCLIInvocation(arguments: [command, "--project", root.path, "--format", "json"]))
            #expect(report.ok, Comment(rawValue: report.diagnostics.map(\.message).joined(separator: "\n")))
            #expect(report.exitCode == 0)
            let decoded = try JSONDecoder().decode(EditorCLIReport.self, from: report.encoded())
            #expect(decoded.schemaVersion == 1)
            #expect(decoded.project?.runtime.entry.scene == "Assets/Main.ascn")
            #expect(try Data(contentsOf: metadata) == before)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".ada/cli-build.lock").path))
    }

    @Test func validationReportsTypeLocationsAndMissingScene() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = try ProjectSystem.loadProject(at: root)
        project.build.adaScriptTypeChecking = .strict
        try ProjectSystem.saveProject(project, at: root)
        try "func wrong() -> Int { return \"bad\"; }".write(to: root.appendingPathComponent("Sources/Main.ada"), atomically: true, encoding: .utf8)
        let invocation = try EditorCLIInvocation(arguments: ["validate", "--project", root.path])
        let invalidTypes = await EditorCLI.execute(invocation)
        #expect(!invalidTypes.ok)
        #expect(invalidTypes.exitCode == 3)
        let diagnostic = try #require(invalidTypes.diagnostics.first)
        #expect(diagnostic.file == "Sources/Main.ada")
        #expect(diagnostic.line == 1)
        #expect((diagnostic.column ?? 0) > 0)
        try "func main() { return 42; }".write(to: root.appendingPathComponent("Sources/Main.ada"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Assets/Main.ascn"))
        let missingScene = await EditorCLI.execute(invocation)
        #expect(!missingScene.ok)
        #expect(missingScene.diagnostics.contains { $0.message.contains("Main.ascn") })
    }

    @Test func symlinkedProjectPathsAreRejected() async throws {
        let root = try fixture()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.moveItem(at: root.appendingPathComponent("Sources"), to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Sources"), withDestinationURL: outside)
        var project = try ProjectSystem.loadProject(at: root)
        project.paths.sources = nil
        project.paths.assets = nil
        try ProjectSystem.saveProject(project, at: root)
        let report = await EditorCLI.execute(try EditorCLIInvocation(arguments: ["validate", "--project", root.path]))
        #expect(report.exitCode == 3)
        #expect(report.diagnostics.contains { $0.message.contains("outside the project") })
    }

    @Test func bundleSDKSurvivesRelocationAndNeverFallsBackToCheckout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Relocated Studio.app")
        let executable = app.appendingPathComponent("Contents/MacOS/adastudio")
        let sdkRoot = app.appendingPathComponent("Contents/Resources/BuildSDK")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(throws: EditorCLIError.self) { try EditorBuildSDK.locate(executable: executable, environment: [:]) }
        for path in ["AdaEngine/Package.swift", "AdaScript/Package.swift", "AdaScript/tools/aot_build.py", "AdaScript/gravity"] {
            let url = sdkRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sdkRoot.appendingPathComponent("AdaScript/gravity").path)
        try Data("{\"schemaVersion\":1}".utf8).write(to: sdkRoot.appendingPathComponent("sdk.json"))
        let sdk = try EditorBuildSDK.locate(executable: executable, environment: [:])
        #expect(sdk.engineRoot.path == sdkRoot.appendingPathComponent("AdaEngine").path)
        #expect(sdk.compilerRoot.path == sdkRoot.appendingPathComponent("AdaScript").path)
    }

    @Test func concurrentBuildLockReleases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("build.lock")
        let lock = try EditorCLIBuildLock(at: url)
        #expect(throws: EditorCLIError.self) { try EditorCLIBuildLock(at: url) }
        lock.release()
        let next = try EditorCLIBuildLock(at: url)
        next.release()
    }

    @Test func buildPreflightRejectsMissingSDKWithoutReplacingOutput() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("Export")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let previous = output.appendingPathComponent("previous.app")
        try Data("old build".utf8).write(to: previous)
        let invocation = try EditorCLIInvocation(arguments: [
            "build", "--project", root.path, "--sdk", root.appendingPathComponent("MissingSDK").path,
            "--output", output.path
        ])
        let report = await EditorCLI.execute(invocation)
        #expect(report.exitCode == 4)
        #expect(try Data(contentsOf: previous) == Data("old build".utf8))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CLI Game \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        var project = ProjectSystem.defaultProject(projectName: "CLI Game", buildSystem: .adaScript)
        project.runtime.entry = .init(scene: "Assets/Main.ascn")
        try ProjectSystem.saveProject(project, at: root)
        try "func main() { return 42; }".write(to: root.appendingPathComponent("Sources/Main.ada"), atomically: true, encoding: .utf8)
        try EditorSceneModel.default(projectName: "CLI Game").encodedYAML().write(to: root.appendingPathComponent("Assets/Main.ascn"), atomically: true, encoding: .utf8)
        return root
    }
}
#endif
