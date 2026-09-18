import Foundation
import Testing

@testable import AdaEditor

@Suite("AdaScript live editor tooling")
@MainActor
struct GravityLiveEditorTests {
    @Test("Opening and editing AdaScript updates inline and problem diagnostics without a build")
    func liveDiagnostics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdaScriptLive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Main.ada")
        let source = "class Main { var speed = 0; var speed = 1 }"
        try source.write(to: file, atomically: true, encoding: .utf8)
        let document = EditorTextDocument(
            id: "main",
            title: "Main.ada",
            relativePath: "Main.ada",
            absolutePath: file.path,
            language: .ada,
            content: source
        )
        let model = EditorViewModel(
            project: EditorProjectReference(name: "Test", path: root.path),
            workspaceService: SwiftPMWorkspaceService(),
            workbench: EditorWorkbenchViewModel(activeEditorTab: .code, openDocuments: [.text(document)])
        )
        model.refreshSemanticTokens(for: .text(document))
        for _ in 0..<200 {
            if model.problems.contains(where: { $0.source == "adascript-lsp" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let diagnostic = try #require(model.problems.first { $0.source == "adascript-lsp" })
        #expect(diagnostic.message == "Duplicate property 'speed' in 'Main'")
        guard case let .text(highlighted)? = model.workbench.activeDocument else {
            Issue.record("Expected an active code document")
            return
        }
        #expect(highlighted.diagnostics.contains(diagnostic))
        model.replaceBuildDiagnostics(with: [])
        #expect(model.problems.contains(diagnostic))

        var fixed = highlighted
        fixed.content = "class Main { var speed = 0 }"
        model.workbench.updateTextDocument(id: fixed.id) { $0.content = fixed.content }
        model.refreshSemanticTokens(for: .text(fixed))
        for _ in 0..<200 {
            if !model.problems.contains(where: { $0.source == "adascript-lsp" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.problems.isEmpty)
        guard case let .text(cleared)? = model.workbench.activeDocument else {
            Issue.record("Expected an active code document")
            return
        }
        #expect(cleared.diagnostics.isEmpty)
    }

    @Test("Command hover highlights a component from disk using the real workspace service")
    func componentHover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdaScriptLiveHover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let component = root.appendingPathComponent("VladComponent.ada")
        try "@component class VladComponent { var someValue = 0 }".write(to: component, atomically: true, encoding: .utf8)
        let file = root.appendingPathComponent("Main.ada")
        let source = "/* 🎮 */ VladComponent().someValue = 0"
        try source.write(to: file, atomically: true, encoding: .utf8)
        let service = SwiftPMWorkspaceService()
        await service.configureSourceWorkspace(projectURL: root)
        let document = EditorTextDocument(
            id: "main",
            title: "Main.ada",
            relativePath: "Main.ada",
            absolutePath: file.path,
            language: .ada,
            content: source
        )
        let model = EditorViewModel(
            project: EditorProjectReference(name: "Test", path: root.path),
            workspaceService: service,
            workbench: EditorWorkbenchViewModel(activeEditorTab: .code, openDocuments: [.text(document)])
        )
        let position = EditorSourceLocation(line: 0, character: 12)
        model.handleSourceHover(document: document, position: position)
        for _ in 0..<200 {
            if case let .text(updated)? = model.workbench.activeDocument, updated.sourceHoverRange != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard case let .text(hovered)? = model.workbench.activeDocument else {
            Issue.record("Expected an active code document")
            return
        }
        #expect(
            hovered.sourceHoverRange
                == EditorSourceRange(
                    start: EditorSourceLocation(line: 0, character: 8),
                    end: EditorSourceLocation(line: 0, character: 21)
                )
        )
        #expect(hovered.sourceHoverDescription?.contains("VladComponent") == true)
        let targets = await service.definition(fileURL: file, language: .ada, text: source, position: position)
        #expect(targets.first?.filePath == component.path)
        model.handleSourceHover(document: hovered, position: nil)
        guard case let .text(cleared)? = model.workbench.activeDocument else {
            return
        }
        #expect(cleared.sourceHoverRange == nil)
    }
}
