@_spi(AdaEngine) import AdaEngine
import AdaScriptCompilerCore
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@Suite("AdaScript libraries", .serialized)
struct AdaScriptLibraryTests {
    @Test("GitHub resolves a tag once and downloads regular UTF-8 files from the pinned tree")
    func githubProvider() async throws {
        let package = Self.package("example.steps", source: "func libraryStep() { return 3; }")
        let manifest = try JSONEncoder().encode(package.manifest)
        let code = try #require(package.files["Sources/Logic.ada"])
        let provider = GitHubAdaScriptLibraryProvider { request in
            let url = try #require(request.url)
            let path = url.path
            if path.hasSuffix("/commits/v1.0.0") {
                return Data("{\"sha\":\"\(Self.sha)\"}".utf8)
            }
            if path.hasSuffix("/git/trees/\(Self.sha)") {
                #expect(url.query == "recursive=1")
                return try JSONSerialization.data(withJSONObject: [
                    "truncated": false,
                    "tree": [
                        ["path": "ada-library.json", "mode": "100644", "type": "blob", "sha": Self.manifestSHA, "size": manifest.count],
                        ["path": "Sources/Logic.ada", "mode": "100644", "type": "blob", "sha": Self.codeSHA, "size": code.count],
                    ],
                ])
            }
            let data = path.hasSuffix(Self.manifestSHA) ? manifest : code
            #expect(path.hasSuffix(Self.manifestSHA) || path.hasSuffix(Self.codeSHA))
            return try JSONSerialization.data(withJSONObject: ["encoding": "base64", "content": data.base64EncodedString()])
        }
        let result = try await provider.download(.init(provider: "github", location: "example/steps", revision: "v1.0.0"))
        #expect(result.source.revision == Self.sha)
        #expect(result.manifest == package.manifest)
        #expect(result.files == package.files)
    }

    @Test("GitHub rejects truncated trees and symbolic-link manifests")
    func unsafeGitHubTrees() async throws {
        for truncated in [true, false] {
            let provider = GitHubAdaScriptLibraryProvider { request in
                if request.url?.path.contains("/commits/") == true {
                    return Data("{\"sha\":\"\(Self.sha)\"}".utf8)
                }
                return try JSONSerialization.data(withJSONObject: [
                    "truncated": truncated,
                    "tree": [["path": "ada-library.json", "mode": "120000", "type": "blob", "sha": Self.manifestSHA, "size": 10]],
                ])
            }
            await #expect(throws: (any Error).self) {
                try await provider.download(.init(provider: "github", location: "example/test", revision: "v1.0.0"))
            }
        }
    }

    @Test("Empty projects and unsupported library versions fail predictably")
    func compatibility() throws {
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try AdaScriptLibraryLock.load(at: root).loadSources(at: root).isEmpty)
        var manifest = AdaScriptLibraryManifest(id: "example.test", version: "1.0.0", sources: ["Main.ada"])
        manifest.api = 2
        #expect(throws: (any Error).self) { try manifest.validate() }
        manifest.api = 1
        manifest.sources = ["Main.ada", "main.ada"]
        #expect(throws: (any Error).self) { try manifest.validate() }
        manifest.sources = ["Main.ada"]
        manifest.version = "latest"
        #expect(throws: (any Error).self) { try manifest.validate() }
    }

    @Test("Installation persists transitive dependencies, supports offline loading, and prunes unused dependencies")
    func dependencyLifecycle() async throws {
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = Self.package("example.helper", source: "func sharedValue() { return 3; }")
        let library = Self.package(
            "example.game",
            source: "func gameValue() { return 4; }",
            dependencies: [
                .init(id: helper.manifest.id, source: helper.source)
            ]
        )
        let manager = EditorAdaScriptLibraryManager(provider: FixtureProvider(packages: [helper, library]))
        let installed = try await manager.install(library.source, at: root)
        #expect(try installed.orderedLibraries().map(\.manifest.id) == ["example.helper", "example.game"])
        #expect(try AdaScriptLibraryLock.load(at: root) == installed)
        #expect(try installed.loadSources(at: root).count == 2)
        _ = try await manager.install(helper.source, at: root)
        let removed = try await manager.remove(library.manifest.id, at: root)
        #expect(removed.roots == [helper.manifest.id])
        #expect(removed.libraries.map(\.manifest.id) == [helper.manifest.id])
        let empty = try await manager.remove(helper.manifest.id, at: root)
        #expect(try empty.loadSources(at: root).isEmpty)
    }

    @Test("Failed updates and cycles leave the previous installation unchanged")
    func rollbackAndCycle() async throws {
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Self.package("example.game", source: "func original() { return 1; }")
        var broken = Self.package("example.broken", source: "func broken() {}")
        broken.manifest.dependencies = [.init(id: "example.missing", source: original.source)]
        var cycle = Self.package("example.cycle", source: "func cycle() {}")
        cycle.manifest.dependencies = [.init(id: cycle.manifest.id, source: cycle.source)]
        let manager = EditorAdaScriptLibraryManager(provider: FixtureProvider(packages: [original, broken, cycle]))
        let installed = try await manager.install(original.source, at: root)
        await #expect(throws: (any Error).self) { try await manager.install(broken.source, at: root) }
        await #expect(throws: (any Error).self) { try await manager.install(cycle.source, at: root) }
        #expect(try AdaScriptLibraryLock.load(at: root) == installed)
        #expect(try installed.loadSources(at: root).first?.source.contains("original") == true)
    }

    @Test("Different pinned revisions of a shared dependency are rejected")
    func conflictingVersions() async throws {
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Self.package("example.shared", source: "func value() { return 1; }")
        var second = first
        second.source.revision = String(repeating: "b", count: 40)
        let consumer = Self.package(
            "example.consumer",
            source: "func consumer() {}",
            dependencies: [
                .init(id: first.manifest.id, source: second.source)
            ]
        )
        let manager = EditorAdaScriptLibraryManager(provider: FixtureProvider(packages: [first, second, consumer]))
        let installed = try await manager.install(first.source, at: root)
        await #expect(throws: (any Error).self) { try await manager.install(consumer.source, at: root) }
        #expect(try AdaScriptLibraryLock.load(at: root) == installed)
    }

    @Test("Restore downloads the locked revision and repairs missing files")
    func restore() async throws {
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = Self.package("example.restore", source: "func restored() { return 7; }")
        let manager = EditorAdaScriptLibraryManager(provider: FixtureProvider(packages: [package]))
        let installed = try await manager.install(package.source, at: root)
        let directory = try #require(installed.libraries.first?.directory)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".ada/libraries/\(directory)"))
        #expect(throws: (any Error).self) { try installed.loadSources(at: root) }
        let restored = try await manager.restore(at: root)
        #expect(try restored.loadSources(at: root).first?.source == "func restored() { return 7; }")
        #expect(restored.libraries.first?.source == package.source)
    }

    @Test("Manifest traversal and symlink escapes are rejected")
    func invalidPaths() throws {
        for path in ["../Secret.ada", "/Secret.ada", "Sources/../../Secret.ada", "Sources\\Secret.ada", "Sources/Main.swift"] {
            let manifest = AdaScriptLibraryManifest(id: "example.test", version: "1.0.0", sources: [path])
            #expect(throws: (any Error).self) { try manifest.validate() }
        }
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".ada/libraries"), withDestinationURL: root.deletingLastPathComponent())
        #expect(throws: (any Error).self) { try AdaScriptLibraryLock.containedURL(".ada/libraries/Secret.ada", in: root) }
    }

    @Test("Installed library imports execute in the game, build, and unsaved Preview")
    @MainActor
    func runtimeAndPreview() async throws {
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = Self.package(
            "example.steps",
            source: """
                func libraryStep() { return 3; }
                @system(id: "example.library-system") class InstalledLibrarySystem {
                    @query(LibraryPosition) var entities;
                    func update(context) {
                        for (var entity in entities) { entity.libraryPosition.value += 1; }
                    }
                }
                @scriptable(id: "example.library-object") class InstalledLibraryObject {}
                """
        )
        let manager = EditorAdaScriptLibraryManager(provider: FixtureProvider(packages: [package]))
        _ = try await manager.install(package.source, at: root)
        let source = """
            import { libraryStep } from "@example.steps/Sources/Logic";
            @system(id: "game.library")
            class LibrarySystem {
                @query(LibraryPosition) var entities;
                func update(context) {
                    for (var entity in entities) { entity.libraryPosition.value += libraryStep(); }
                }
            }
            """
        try source.write(to: root.appendingPathComponent("Sources/Main.ada"), atomically: true, encoding: .utf8)
        var project = try ProjectSystem.loadProject(at: root)
        project.runtime.entry = AdaProjectRuntimeEntry()
        LibraryPosition.registerComponent()
        let artifact = try EditorAdaScriptProjectBuilder().prepare(project: project, at: root)
        #expect(artifact.report.sourceCount == 2)
        #expect(artifact.report.systemCount == 2)
        let catalog = try EditorScriptableObjectCatalogLoader.load(project: project, at: root)
        #expect(catalog.descriptors.map(\.identifier) == ["example.library-object"])
        let plugin = try AdaScriptPlugin(sources: artifact.sources, name: "LibraryGame")
        let world = World(name: "LibraryGame")
        let entity = world.spawn { LibraryPosition(value: 1) }
        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)
        #expect(world.get(LibraryPosition.self, from: entity.id)?.value == 5)
        #expect(plugin.diagnostics.isEmpty)

        let previewSource = """
            import { libraryStep } from "@example.steps/Sources/Logic";
            @previewable @view class LibraryHUD { func body() { Text("Library").fontSize(libraryStep()); } }
            """
        let declaration = try #require(EditorPreviewScanner.declarations(in: previewSource, language: .ada).first)
        let document = EditorTextDocument(
            id: "main",
            title: "Main.ada",
            relativePath: "Sources/Main.ada",
            absolutePath: root.appendingPathComponent("Sources/Main.ada").path,
            language: .ada,
            content: previewSource,
            lastSavedContent: source
        )
        let preview = try await EditorAdaScriptPreviewBuilder()
            .build(
                .init(
                    projectURL: root,
                    document: document,
                    packageModel: nil,
                    declaration: declaration
                ) as EditorAdaScriptPreviewBuildRequest
            )
        try AdaScriptView.validate(sources: preview.sources, identifier: "LibraryHUD")
        #expect(preview.sources.contains { $0.source == previewSource })
    }

    @Test("Library panel Install button writes a library that survives reopening")
    @MainActor
    func libraryPanelInteraction() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "LibrarySettingsTests")))
        }
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = Self.package("example.ui", source: "func uiValue() { return 1; }")
        let manager = EditorAdaScriptLibraryManager(provider: FixtureProvider(packages: [package]))
        let model = EditorLibrariesViewModel(manager: manager)
        model.load(at: root)
        model.repository = package.source.location
        model.revision = package.source.revision
        let container = UIContainerView(rootView: EditorLibrariesView(viewModel: model))
        container.frame = Rect(x: 0, y: 0, width: 320, height: 500)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Libraries.Install"))
        for _ in 0..<100 where model.lock.libraries.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.lock.roots == [package.manifest.id])
        let reopened = EditorLibrariesViewModel(manager: manager)
        reopened.load(at: root)
        #expect(reopened.lock == model.lock)
    }

    private static let sha = String(repeating: "a", count: 40)
    private static let manifestSHA = String(repeating: "c", count: 40)
    private static let codeSHA = String(repeating: "d", count: 40)

    private static func package(
        _ id: String,
        source: String,
        dependencies: [AdaScriptLibraryDependency] = []
    ) -> AdaScriptLibraryDownload {
        .init(
            manifest: .init(id: id, version: "1.0.0", sources: ["Sources/Logic.ada"], dependencies: dependencies),
            source: .init(provider: "github", location: "example/\(id)", revision: sha),
            files: ["Sources/Logic.ada": Data(source.utf8)]
        )
    }

    private static func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdaScriptLibraries-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Game", buildSystem: .adaScript), at: root)
        return root
    }
}

private struct FixtureProvider: AdaScriptLibraryProvider {
    let packages: [AdaScriptLibraryDownload]
    func download(_ source: AdaScriptLibrarySource) async throws -> AdaScriptLibraryDownload {
        guard let package = packages.first(where: { $0.source == source }) else {
            throw AdaScriptLibraryError.invalid("Fixture not found: \(source.location)")
        }
        return package
    }
}

@Component
private struct LibraryPosition {
    var value: Double
}
