@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@Suite("Project packaging", .serialized)
struct EditorProjectPackagingTests {
    @Test("folder format is independent of the language template", arguments: [false, true], EditorProjectTemplate.allCases)
    func createsAndReopensProject(asPackage: Bool, template: EditorProjectTemplate) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectPackaging-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EditorProjectStore(storageURL: root.appendingPathComponent("recent.json"), distribution: .standalone)
        let reference = try store.createProject(named: "My Game", at: root, template: template, asPackage: asPackage)
        let url = URL(fileURLWithPath: reference.path)
        #expect(url.lastPathComponent == (asPackage ? "My-Game.adaproject" : "My-Game"))
        let metadata = try ProjectSystem.loadProject(at: url)
        #expect(metadata.project.name == "My-Game")
        #expect(metadata.build.system == (template == .adaScript ? .adaScript : .swiftpm))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("Sources", isDirectory: true).path))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) == (template == .adaScriptWithSwift))
        #expect(try store.openProject(at: url).path == reference.path)
    }

    @Test("platform default and launcher switch reach the real filesystem")
    @MainActor
    func launcherPackageToggle() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "PackagingUI")))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PackagingUI-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EditorProjectStore(storageURL: root.appendingPathComponent("recent.json"), distribution: .standalone)
        let model = ProjectOpeningViewModel(store: store)
        #if os(iOS)
            #expect(EditorProjectStore.defaultUsesProjectPackage)
        #else
            #expect(!EditorProjectStore.defaultUsesProjectPackage)
        #endif
        model.beginCreateNewProject(template: .adaScript, suggestedName: "Toggled")
        #expect(model.shouldCreateProjectPackage == EditorProjectStore.defaultUsesProjectPackage)
        model.setProjectLocation(root)
        model.shouldCreateGitRepository = false
        let container = UIContainerView(rootView: ProjectOpeningView(autoOpenLastProject: false, viewModel: model))
        container.frame = Rect(x: 0, y: 0, width: 1300, height: 1000)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.packageToggle))
        #expect(model.shouldCreateProjectPackage != EditorProjectStore.defaultUsesProjectPackage)
        let packaged = model.shouldCreateProjectPackage
        model.createProject(openInEditor: true)
        let reference = try #require(model.projectToOpenInEditor)
        #expect(URL(fileURLWithPath: reference.path).pathExtension == (packaged ? "adaproject" : ""))
        #expect(ProjectSystem.isAdaProject(at: URL(fileURLWithPath: reference.path)))
        model.beginCreateNewProject()
        #expect(model.shouldCreateProjectPackage == EditorProjectStore.defaultUsesProjectPackage)
    }

    @Test(
        "all application variants own the same project document type",
        arguments: [
            "Sources/AdaEditor/Platforms/macOS/Info.plist",
            "Platforms/StandaloneUpdater/App-Info.plist",
            "Sources/AdaEditor/Platforms/iOS/Info.plist",
        ]
    )
    func documentRegistration(path: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bytes = try Data(contentsOf: root.appendingPathComponent(path))
        let plist = try #require(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        let types = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let exported = try #require(types.first { $0["UTTypeIdentifier"] as? String == "org.adaengine.project" })
        #expect(exported["UTTypeConformsTo"] as? [String] == ["com.apple.package"])
        let tags = try #require(exported["UTTypeTagSpecification"] as? [String: Any])
        #expect(tags["public.filename-extension"] as? [String] == ["adaproject"])
        let documents = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let document = try #require(documents.first { ($0["LSItemContentTypes"] as? [String])?.contains("org.adaengine.project") == true })
        #expect(document["LSHandlerRank"] as? String == "Owner")
        #expect(document["CFBundleTypeRole"] as? String == "Editor")
    }
}
