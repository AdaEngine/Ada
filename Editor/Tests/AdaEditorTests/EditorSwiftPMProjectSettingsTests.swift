import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("SwiftPM project settings")
struct EditorSwiftPMProjectSettingsTests {
    @Test("Targets uses SwiftPM membership for custom and shared source directories")
    func customSourceMembership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftPMTargets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let native = root.appendingPathComponent("Native")
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        let manifest = """
            // swift-tools-version: 6.2
            import PackageDescription
            let package = Package(name: "Game", targets: [
                .executableTarget(name: "Game", path: "Native", exclude: ["Notes.swift", "GameTests.swift"]),
                .testTarget(name: "GameTests", path: "Native", exclude: ["Notes.swift", "main.swift"])
            ])
            """
        try manifest.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        for source in ["main.swift", "GameTests.swift", "Notes.swift"] {
            try "".write(to: native.appendingPathComponent(source), atomically: true, encoding: .utf8)
        }
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Game", buildSystem: .swiftpm), at: root)
        let result = await SwiftPMWorkspaceService().execute(.describe, projectURL: root)
        let package = try #require(SwiftPackageModel.parse(from: result.standardOutput), "\(result.combinedOutput)")
        let editor = EditorViewModel(project: EditorProjectReference(name: "Game", path: root.path), packageModel: package)
        editor.projectSidebar.expandAll()
        let rows = editor.projectSidebar.visibleItems
        #expect(rows.map(\.title) == ["Game", "main.swift", "GameTests", "GameTests.swift"])
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(editor.projectSidebar.revealFile(relativePath: "Native/GameTests.swift"))
        #expect(editor.projectSidebar.displayMode == .targets)
        editor.projectSidebar.selectDisplayMode(.files)
        #expect(editor.projectSidebar.visibleItems.contains { $0.relativePath == "Native/Notes.swift" })
    }
}
