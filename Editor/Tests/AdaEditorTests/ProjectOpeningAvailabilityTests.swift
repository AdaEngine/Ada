import Foundation
import Testing

@testable import AdaEditor

@Suite("Project opening availability")
@MainActor
struct ProjectOpeningAvailabilityTests {
    @Test("recent projects reflect removal and restoration without losing their saved entry")
    func refreshAvailability() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EditorProjectStore(storageURL: root.appendingPathComponent("projects.json"))
        let reference = try store.createProject(named: "Portable", at: root, template: .adaScript)
        let model = ProjectOpeningViewModel(store: store)
        await model.refreshProjectAvailability()
        #expect(model.projectAvailability[reference.path] == .init(isAvailable: true, containsSwiftCode: false))

        let original = URL(fileURLWithPath: reference.path)
        let moved = root.appendingPathComponent("Moved.adaproject")
        try FileManager.default.moveItem(at: original, to: moved)
        await model.refreshProjectAvailability()
        #expect(model.projectAvailability[reference.path]?.isAvailable == false)
        #expect(model.recentProjects.count == 1)
        try FileManager.default.moveItem(at: moved, to: original)
        await model.refreshProjectAvailability()
        #expect(model.projectAvailability[reference.path]?.isAvailable == true)
    }

    @Test("SwiftPM badge requires Swift sources, not just a manifest or build artifacts")
    func requiresSwiftSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "// swift-tools-version: 6.2".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        _ = try ProjectSystem.createDefaultProject(at: root, buildSystem: .swiftpm)
        #expect(!ProjectOpeningAvailability.inspect(at: root).containsSwiftCode)
        let build = root.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try "import Foundation".write(to: build.appendingPathComponent("generated.swift"), atomically: true, encoding: .utf8)
        #expect(!ProjectOpeningAvailability.inspect(at: root).containsSwiftCode)

        var project = try ProjectSystem.loadProject(at: root)
        project.paths.sources = "GameCode"
        try ProjectSystem.saveProject(project, at: root)
        let sources = root.appendingPathComponent("GameCode/Nested")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let source = sources.appendingPathComponent("main.swift")
        try "print(42)".write(to: source, atomically: true, encoding: .utf8)
        #expect(ProjectOpeningAvailability.inspect(at: root).containsSwiftCode)
        try FileManager.default.removeItem(at: source)
        #expect(!ProjectOpeningAvailability.inspect(at: root).containsSwiftCode)
    }

    @Test("project type dropdown updates the template used by project creation")
    func projectTypeSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = ProjectOpeningViewModel(store: EditorProjectStore(storageURL: root.appendingPathComponent("projects.json")))
        #expect(model.projectTemplateBinding.wrappedValue == "AdaScript")
        model.projectTemplateBinding.wrappedValue = "AdaScript + Swift"
        #expect(model.selectedTemplate == .adaScriptWithSwift)
        model.projectTemplateBinding.wrappedValue = "AdaScript"
        #expect(model.selectedTemplate == .adaScript)
        model.shouldCreateGitRepositoryBinding.wrappedValue.toggle()
        #expect(!model.shouldCreateGitRepository)
    }
}
