import Foundation
import Testing

@testable import AdaEditor

@Suite("Editor distribution channels")
struct EditorDistributionTests {
    @Test func channelResolution() {
        #expect(EditorDistribution.resolve(channel: "standalone", isAppBundle: true) == .standalone)
        #expect(EditorDistribution.resolve(channel: "appStore", isAppBundle: true) == .appStore)
        #expect(EditorDistribution.resolve(channel: nil, isAppBundle: true) == .appStore)
        #expect(EditorDistribution.resolve(channel: "invalid", isAppBundle: true) == .appStore)
        #expect(EditorDistribution.resolve(channel: nil, isAppBundle: false) == .standalone)
        #expect(EditorDistribution.appStore.projectTemplates == [.adaScript])
        #expect(EditorDistribution.standalone.projectTemplates == [.adaScript, .adaScriptWithSwift])
    }

    @Test @MainActor func appStoreCreatesAndBuildsAdaScript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EditorProjectStore(storageURL: root.appendingPathComponent("recents.json"), distribution: .appStore)
        let reference = try store.createProject(named: "Script", at: root, template: .adaScript)
        let url = URL(fileURLWithPath: reference.path)
        let project = try ProjectSystem.loadProject(at: url)
        let report = try EditorAdaScriptProjectBuilder().build(project: project, at: url)
        #expect(report.viewCount == 1)
        #expect(try store.openProject(at: url).path == reference.path)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path))
        let launcher = ProjectOpeningViewModel(store: store)
        #expect(launcher.availableTemplates == [.adaScript])
        #expect(!launcher.shouldCreateGitRepository)
    }

    @Test func appStoreRejectsHybridWithoutMutatingProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let restricted = EditorProjectStore(storageURL: root.appendingPathComponent("store-recents.json"), distribution: .appStore)
        #expect(throws: EditorDistributionError.self) {
            try restricted.createProject(named: "Blocked", at: root, template: .adaScriptWithSwift)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Blocked").path))
        let full = EditorProjectStore(storageURL: root.appendingPathComponent("recents.json"), distribution: .standalone)
        let reference = try full.createProject(named: "Hybrid", at: root, template: .adaScriptWithSwift)
        let url = URL(fileURLWithPath: reference.path)
        let manifest = url.appendingPathComponent("Package.swift")
        let before = try Data(contentsOf: manifest)
        #expect(throws: EditorDistributionError.self) { try restricted.openProject(at: url) }
        #expect(try Data(contentsOf: manifest) == before)
        #expect(!FileManager.default.fileExists(atPath: restricted.storageURL.path))
        #expect(try full.openProject(at: url).path == reference.path)
    }
}
